let s:ce_asm_view = 0
let s:channel = 0


func LogHandler(channel, msg, fd)
    call ch_log(a:fd . ": " . a:msg)
endfunc


func LogStdout(channel, msg)
    if a:msg =~? 'Listening on http://'
        " call InitAsmView()
    endif
    call LogHandler(a:channel, a:msg, 'stdout')

endfunc


func LogStderr(channel, msg)
    call LogHandler(a:channel, a:msg, 'stderr')
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
"   call ch_log("-------------------body--------------------")
"   call ch_log(a:body[start_idx:])
"   call ch_log("-------------------endbody--------------------")
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
"   call ch_log("-------------------startchunk--------------------")
"   call ch_log(chunk)
"   call ch_log("-------------------endchunk--------------------")
        call add(chunks, chunk)
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
"   call ch_log('-------------HTTP request------------')
"   call ch_log(request)
"   call ch_log('-------------end HTTP request------------')
"   let Callback = function(a:callback)
    call ch_sendraw(
    \   s:channel,
    \   request,
    \   {'callback': {ch, msg -> HttpResponseHandler(ch, msg, function(a:callback))}}
    \)
endfunc


func InitAsmView()
    let oldwin = win_getid()
    vertical rightb split [AsmView]
    setlocal readonly nowrap syn=asm ft=asm
    setlocal buftype=nofile noswapfile bufhidden=delete
    " Switch back to the old window
    let newwin = win_getid()
    call assert_false(oldwin == newwin)
    call win_gotoid(oldwin)
    return newwin
endfunc


func UpdateAsmView(data)
    if a:data.status != 200
        echoe "Request failed"
        return
    endif
    let data = a:data.json
    let lines = {}
    let n_colors = 16
    let color_ids = map(g:ce_highlight_colors,
                \{idx, val -> [val, 'ce_highlight_ref_' . idx]})

    for [color_id, group_name] in color_ids
        exe printf('highlight %s ctermbg=%d', group_name, color_id)
    endfor
    let colormap = {'src': {}, 'asm': {}}
    let asm_line = 0
    let color_idx = 0
    let asm_lines = repeat([''], len(data['asm']))
    let lastsrc = 0
    if g:ce_enable_higlights
        for lineinfo in data['asm']
            call ch_log(json_encode(lineinfo))
            if (has_key(lineinfo, 'source')) &&
                        \(type(lineinfo['source']) != type(v:null))
                let srcline = lineinfo['source']['line']
                if lastsrc != srcline
                    let lastsrc = srcline
                    let color_idx += 1
                endif
                let [_, colorname] = color_ids[color_idx % n_colors]
                let colormap['src'][srcline] = colorname
                let colormap['asm'][asm_line] = colorname
            endif
            let asm_lines[asm_line] = lineinfo['text']
            let asm_line += 1
        endfor
    endif

    " This is a total hack until I work out how to write into another buffer
    " cleanly
    let oldwin = win_getid()
    if (!s:ce_asm_view) || oldwin ==? s:ce_asm_view
        return
    endif
    if g:ce_enable_higlights
        for [line, group_name] in items(colormap['src'])
            call matchaddpos(group_name, [[0+line, 1]])
        endfor
    endif
    call win_gotoid(s:ce_asm_view)
    if g:ce_enable_higlights
        for [line, group_name] in items(colormap['asm'])
            call matchaddpos(group_name, [[1+line, 1]])
        endfor
    endif
    setlocal modifiable noreadonly
    call execute(':%delete _')
    call setline(1, asm_lines)
    setlocal nomodifiable readonly
    " Switch back to the old window
    call win_gotoid(oldwin)
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
    if ce_lang == 'cpp'
        let ce_lang = 'c++'
    endif
    let std = g:ce_language_standard[ce_lang]
    let compiler = HttpSimpleQuotePath(g:ce_enabled_compilers[ce_lang][0])
    let opt = g:ce_optlevel[ce_lang]
    let cflags = ['-x' . ce_lang, '-std=' . std, '-O' . opt]
    call extend(cflags, ExtraCFLAGS(expand('%:p')))
    let filters = {
    \    'labels': v:true,
    \    'directives': g:ce_strip_directives ? v:true : v:false,
    \    'commentOnly': (!g:ce_strip_comments) ? v:false : v:true,
    \    'trim': v:true,
    \    'intel': (g:ce_asm_fmt ==? 'intel') ? v:true : v:false,
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


func ce#toggle_asm_view()
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
