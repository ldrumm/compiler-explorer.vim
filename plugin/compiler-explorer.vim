" compiler-explorer.vim - vim Wrapper for Matt Godbolt's Compiler Explorer
" inline assembly viewer (https://gcc.godbolt.org)
" Author: ldrumm <ldrumm@users.github.com>
" Version: 0.0.0
" License: TODO
" Source repository: https://github.com/ldrumm/compiler-explorer.vim

" Initialization {{{
if exists('g:loaded_ce') || &cp
  finish
else
    let g:loaded_ce = 1
    let s:ce_asm_view = 0
    let s:channel = 0
endif

if !has('channel') || !has('job')
    echoe "channel or job support is required for compiler explorer assembly view"
    finish
endif
" }}}


" Timeout for downloading HTTP responses from the server. Set this as low as
" possible, as it blocks the UI
let g:ce_http_recv_timeout = get(g:, 'ce_http_recv_timeout', 1)

" Path to the compiler explorer makefile used to launch compiler explorer.
" If this is empty or falsey, it will be assumed compiler explorer
" is managed elsewhere and always already running on the given port
let g:ce_makefile = get(g:, 'ce_makefile', 0)

" The host on which compiler explorer runs
let g:ce_host = get(g:, 'ce_host', 'localhost')

" TCP listen port for compiler explorer
let g:ce_port = get(g:, 'ce_port', 10240)
" TODO
let g:ce_highlight_colors = get(g:, 'ce_highlight_colors', 1)
" Languages to compile
let g:ce_enabled_languages = get(g:, 'ce_enabled_languages', ['c', 'c++'])

let g:ce_enabled_compilers =
    \get(g:, 'ce_enabled_compilers',
    \{'c': [exepath('g++')], 'c++': [exepath('g++')]})
let g:ce_language_standard =
    \get(g:, 'ce_language_standard', {'c': 'c99', 'c++': 'c++11'})
let g:ce_optlevel = get(g:, 'g:ce_optlevel', {'c': 0, 'c++': 0})
" TODO If [YouCompleteMe](https://github.com/Valloric/YouCompleteMe) is installed,
" use it for cflags
let g:ce_use_ycm_extra_conf = get(g:, 'g:ce_use_ycm_extra_conf', 0)
let g:ce_daemonize = get(g:, 'g:ce_daemonize', 0)
" Anyone who prefers intel style syntax is a pervert who should rethink all
" they know. However, we should also be mindful that perverts are people too,
" and should be granted the freedom to express such perversions
let g:ce_asm_fmt = 'att'
" remove compiler-generated comments from the output
let g:ce_strip_comments = 1
" assemble then dissasemble, rather than just compile
let g:ce_disasm = 0
" Remove useless assembler directives
let g:ce_strip_directives = 1


func LogHandler(channel, msg, fd)
    call ch_log(a:fd . ": " . a:msg)
endfunc


func LogStdout(channel, msg)
    if a:msg =~ 'Listening on http://'
        " call InitAsmView()
    endif
    call LogHandler(a:channel, a:msg, 'stdout')

endfunc


func LogStderr(channel, msg)
    call LogHandler(a:channel, a:msg, 'stderr')
endfunc


func ChannelHandler(channel, msg)
    echo "got a message" . a:msg
endfunc


func HttpSimpleQuotePath(s)
    " do the bare minimum substitution to get /usr/bin/g++ to work in a URL
    " FIXME at some point someone will have a compiler on a strange path, and
    " we should properly quote this in all generality
    let s = a:s
    for [pat, repl] in [['/', '%2F'], ['+', '%2B'], [' ', '%20']]
        let s = substitute(s, pat, repl, "g")
    endfor
    return s
endfunc


func HttpParseChunkedResponse(body)
    let chunks = []
    let start_idx = 0
    let loop = 0
    while 1
    call ch_log("-------------------body--------------------")
    call ch_log(a:body[start_idx:])
    call ch_log("-------------------endbody--------------------")
        let pat = matchlist(a:body[start_idx:], '^\([0-9a-fA-f]\+\)')
        if len(pat) == 0
            call ch_log(join(pat, ","))
            echoe "invalid chunk encoding"
            return
        endif
        let chunk_len = (0 + ("0x" . pat[1]))
        if chunk_len == 0
            break
        end
        let start_idx += len(pat[1]) + 2
        let end_idx = start_idx + chunk_len
        let chunk = a:body[start_idx:end_idx]
        let start_idx = end_idx + 2
    call ch_log("-------------------startchunk--------------------")
    call ch_log(chunk)
    call ch_log("-------------------endchunk--------------------")
        call add(chunks, chunk)
        call ch_log("loop: ". loop)
        let loop += 1
    endwhile
    let body = join(chunks, '')
    return body
endfunc


func HttpParseResponse(response)
    " separate Response header from the body
    let body_start = match(a:response, "\r\n\r\n")
    if body_start == -1
        echoe "invalid http response"
        return
    endif
    let [meta, body] = [a:response[:body_start -1], a:response[body_start + 4:]]
    let meta = split(meta, "\r\n")
    let [statusline, headerlines] = [meta[0], meta[1:]]
    let pat = matchlist(statusline, '^HTTP/1.\(0\|1\) \([1-5][0-9][0-9]\) \(\w\+\)')
    if !len(pat)
        echoe "invalid statusline" . statusline
        return
    endif
    let http_proto = 0 + pat[1]
    if (http_proto != 0) && (http_proto != 1)
        echoe "unsupported http protocol " . http_proto
        return
    endif
    let status = 0 + pat[2]
    let description = pat[3]
    let headers = {}
    for line in headerlines
        let pat = matchlist(line, '^\(.*\): \(.*\)$')
        if !len(pat)
            return
        endif
        let [pat, key, val] = pat[:2]
        if (!len(pat)) || (!len(val)) || (!len(key))
            echoe "invalid HTTP response: pat:" . pat "val:" . val . "key:" . key
            return
        endif
        " Normalize header keys
        let key = tolower(substitute(key, "_", "-", "g"))
        let headers[key] = val
    endfor
    if !has_key(headers, 'content-length')
        if has_key(headers, 'transfer-encoding')
                    \&& headers['transfer-encoding'] =~ 'chunked'
            let body = HttpParseChunkedResponse(body)
        endif
    elseif !(len(body) == headers['content-length'])
        echoe "invalid content length"
        return
    endif
    let response = {'status': status, 'headers': headers, 'data': body}
    if has_key(headers, 'content-type')
                \&& headers['content-type'] =~ 'application/json'
        let response['json'] = json_decode(response.data)
    endif
    return response
endfunc


func HttpResponseHandler(channel, msg, callback)
    let parts = [a:msg]
    while 1
        let part = ch_readraw(a:channel, {'timeout': g:ce_http_recv_timeout})
        if part == ''
            break
        endif
        call add(parts, part)
    endwhile
    let output = join(parts, '')
    let data = HttpParseResponse(output)
    return function(a:callback)(data)
endfunc


func HttpSerializeHeader(key, val, ...)
    " hack to make a http header from a [k, v] pair
    " single spaces are allowed, and replaced with a single dash
    " words are then capitalised. If value is a list, it is serialized as
    " comma-separated. All values are coerced to strings in the default
    " manner.
    " Optional arguments: a:1 -> {sep} list separator for list fields default
    " ', '
    if a:0 > 0
        let sep = a:1
    else
        let sep = ", "
    endif

    if type(a:val) != v:t_list
        let vals = [a:val]
    else
        let vals = a:val
    endif

    for val in vals
        if match(val, '[\r\n]') != -1
            echoe "invalid http header value " . val
            return
        endif
    endfor
    if match(a:key, '^\(\w\|-\)\+') != 0 && match(a:key, ' \{2,\}') != -1
        echoe "invalid http header key " . a:key
        return
    endif
    let old_key = split(substitute(a:key, " ", "-", "g"), "-")
    let new_key = []
    for word in old_key
        call add(new_key, toupper(word[0]) . word[1:])
    endfor
    return join(new_key, '-') . ": " . join(vals, ", ")
endfunc


func HttpRequest(channel, path, method, headers, data, callback)
    if ch_status(a:channel) !=? 'open'
        return
    endif

    let method = toupper(a:method)
    call assert_true(has_key({'GET': 1, 'POST': 1}, method))
    if method == 'POST'
        let a:headers['content-length'] = len(a:data)
    endif

    let reqline = join([method, a:path, 'HTTP/1.1'], ' ')
    let headerlines = []
    for [k, v] in items(a:headers)
        call add(headerlines, HttpSerializeHeader(k, v))
    endfor
    let lines = [reqline]
    call extend(lines, headerlines)
    call extend(lines, ['', ''])
    let request = join(lines, "\r\n")
    if a:data || len(a:data)
        let request .= a:data
    endif
    call ch_log('-------------HTTP request------------')
    call ch_log(request)
    call ch_log('-------------end HTTP request------------')
    let Callback = function(a:callback)
    call ch_sendraw(
    \   s:channel,
    \   request,
    \   {'callback': {ch, msg -> HttpResponseHandler(ch, msg, function(a:callback))}})
endfunc


func InitAsmView()
    let oldwin = bufnr('%')
    vertical rightb split [AsmView]
    setlocal readonly nowrap syn=asm ft=asm
    setlocal buftype=nofile noswapfile bufhidden=delete
    au WinLeave <buffer> exe "normal" ":%!python -m json.tool<CR>"

    " Switch back to the old window
    let newwin = bufnr('%')
    exe oldwin . "wincmd w"
    return newwin
endfunc


func UpdateAsmView(data)
    if a:data.status != 200
        echoe "Request failed"
        return
    endif
    let data = a:data.json
    let lines = {}
    for lineinfo in data['asm']
        if (!has_key(lineinfo, 'source')) ||
                    \(type(lineinfo['source']) == type(v:null))
            continue
        endif
        call ch_log(json_encode(lines))
        let lines[lineinfo['source']['line']] = lineinfo['text']
    endfor
    let n_asm_lines = max(keys(lines))
    let asm_lines = repeat([''], n_asm_lines)
    for idx in keys(lines)
        call insert(asm_lines, lines[idx], idx)
    endfor

    " This is a total hack until I work out how to write into another buffer
    " cleanly
    let oldwin = bufnr('%')
    if (!s:ce_asm_view) || oldwin ==? s:ce_asm_view
        return
    endif
    exe s:ce_asm_view . "wincmd w"
    setlocal modifiable noreadonly
    call execute(':%delete _')
    call setline(1, asm_lines)
    setlocal nomodifiable readonly
    " Switch back to the old window
    exe oldwin . "wincmd w"
endfunc


func KillAsmView()
    exe s:ce_asm_view . "wincmd q"
    let s:ce_asm_view = 0
endfunc


func ExtraCFLAGS(source)
    " TODO find compile_commands.json / snatch from Youcompleteme
    return []
endfunc


func CompileDispatch()
    let ce_lang = tolower(&filetype)
    let std = g:ce_language_standard[ce_lang]
    let compiler = HttpSimpleQuotePath(g:ce_enabled_compilers[ce_lang][0])
    let opt = g:ce_optlevel[ce_lang]
    let cflags = ['-x' . ce_lang, '-std=' . std, '-O' . opt]
    call extend(cflags, ExtraCFLAGS(expand('%:p')))
    let filters = {
    \    'labels': v:true,
    \    'directives': v:true,
    \    'commentOnly': v:true,
    \    'trim': v:true,
    \    'intel': v:false,
    \}
    let options = {
    \    'userArguments': join(cflags, ' '),
    \    'filters': filters,
    \    'compilerOptions': {},
    \}
    let source = join(getline('^', '$'), "\n")
    let request = {'compiler': compiler, 'options': options, 'source': source}

    return HttpRequest(
    \    InitChannel(),
    \    '/api/compiler/' . compiler . '/compile',
    \    'post',
    \    {
    \        'host': 'localhost',
    \        'content-type': 'application/json',
    \        'accept': 'application/json',
    \        'accept-encoding': '',
    \    },
    \    json_encode(request),
    \   'UpdateAsmView'
    \)
endfunc


func StartServer()
    let dirname = fnamemodify(g:ce_makefile, ":h")
    let options = {
    \   'cwd': dirname,
    \   'out_cb': 'LogStdout',
    \   'err_cb': 'LogStderr',
    \}
    let extra_args = ['--host=' . g:ce_host, '--port=' . g:ce_port]
    let s:ce_job = job_start(
    \    ['make', 'run', 'EXTRA_ARGS=' . join(extra_args, ' ')],
    \    options
    \)
endfunc


func InitChannel()
    if type(s:channel) == type(0)
            \|| ch_status(s:channel) == 'fail'
            \|| ch_status(s:channel) == 'closed'
        let s:channel = ch_open(g:ce_host . ":" . g:ce_port, {'mode': 'raw'})
        if ch_status(s:channel) == 'fail'
            call StartServer()
        endif
    endif
    return s:channel
endfunc


func CEToggleAsmView()
    if (!exists('s:ce_asm_view')) || !s:ce_asm_view
        let s:ce_asm_view = InitAsmView()
        call CompileDispatch()
        " FIXME This is really noisy. Even when doing nothing this fires an
        " HTTP request every couple of seconds, which is going to trash
        " battery and will probably get pretty hairy on large C++ files
        au CursorHoldI,CursorHold <buffer> call CompileDispatch()
    else
        call KillAsmView()
        au! CursorHoldI,CursorHold <buffer> call CompileDispatch()
    endif
endfunc
