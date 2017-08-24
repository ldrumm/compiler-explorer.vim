" compiler-explorer.vim - vim Wrapper for Matt Godbolt's Compiler Explorer
" inline assembly viewer (https://gcc.godbolt.org)
" Author: ldrumm <ldrumm@users.github.com>
" Version: 0.0.0
" License: TODO
" Source repository: https://github.com/ldrumm/compiler-explorer.vim

" Initialization {{{
if exists('g:loaded_ce') || &compatible
  finish
else
    let g:loaded_ce = 1
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

" Highlight colours to aid the matching of assmebly to source.
let g:ce_enable_higlights = get(g:, 'ce_enable_higlights', 1)
let g:ce_highlight_colors = get(g:, 'ce_highlight_colors', range(200, 255, 5))

" Languages to compile
let g:ce_enabled_languages = get(g:, 'ce_enabled_languages', ['c', 'c++'])

let g:ce_enabled_compilers =
    \get(g:, 'ce_enabled_compilers',
    \{'c': [exepath('g++')], 'c++': [exepath('g++')]})

" The version of the language to target. This is passed to the compiler as
" `-std=$STANDARD`
let g:ce_language_standard =
    \get(g:, 'ce_language_standard', {'c': 'c99', 'c++': 'c++11'})

" Default optimization level
let g:ce_optlevel = get(g:, 'g:ce_optlevel', {'c': 0, 'c++': 0})

" If [YouCompleteMe](https://github.com/Valloric/YouCompleteMe) is installed,
" use it for cflags
let g:ce_use_ycm_extra_conf = get(g:, 'g:ce_use_ycm_extra_conf', 0)

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

command! CEToggleAsmView :call ce#toggle_asm_view()
