# compiler-explorer.vim

## Vim integration for Matt Godbolt's [Compiler Explorer](https://gcc.godbolt.org)

### *WARNING*: This project is a pre-alpha prototype written as a way to learn viml.
### Don't use it for your precious.

This plugin provides assembly-as-you type, allowing all the bikeshedding you can
imagine in the name of performance.

## 2-step Installation

1. Install the plugin as usual. For example, with
   [pathogen](https://github.com/tpope/pathogen.vim):
   ```bash
    cd ~/.vim/bundle
    git clone https://github.com/ldrumm/compiler-explorer.vim
    ```
2. Install Compiler Explorer proper and add the path to your vim config (adjust
   paths to taste):
    ```bash
    CE=$HOME/.local/lib/compiler-explorer
    git clone https://github.com/mattgodbolt/compiler-explorer "$CE"
    cat <<EOF >> ~/.vimrc

    " This is the path to the local Compiler Explorer installation required by
    " [compiler-explorer.vim](https://github.com/ldrumm/compiler-explorer.vim
    let g:ce_makefile = '$CE/Makefile'
    " Toggle display of the compiler-explorer assembly pane with f3
    map <f3> :call CEToggleAsmView()<CR>
    EOF

Note. This plugin require channel, job and json supported introduced with vim8
as well as any dependencies required by compiler-explorer proper.
