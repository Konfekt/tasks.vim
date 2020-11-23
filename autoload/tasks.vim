" ========================================================================///
" Description: Tasks management inspired by asynctasks.vim
" File:        tasks.vim
" Author:      Gianmaria Bajo <mg1979@git.gmail.com>
" License:     MIT
" Created:     mar 08 settembre 2020 01:58:09
" Modified:    mar 08 settembre 2020 01:58:09
" ========================================================================///


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Tasks getters
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Get valid tasks, fetched from both global and project-local config files.
" @param ...: force reloading of config files
" @return: the merged dictionary with tasks
""
function! tasks#get(...) abort
    let reload = a:0 && a:1
    let global = deepcopy(tasks#global(reload))
    let local  = deepcopy(tasks#project(reload))
    let gtasks = deepcopy(global.tasks)
    let all = extend(global, local)
    if s:can_include_global_tasks(all)
        call extend(all.tasks, gtasks, 'keep')
    endif
    return all
endfunction


""
" Get the project-local tasks dictionary.
""
function! tasks#project(reload) abort
    let prj = s:ut.basedir()
    if !a:reload && has_key(g:tasks, prj) && !g:tasks[prj].invalidated
        return g:tasks[prj]
    endif
    let f = s:get_local_ini()
    if !filereadable(f)
        return {}
    endif
    let g:tasks[prj] = tasks#parse#do(readfile(f), 1)
    return g:tasks[prj]
endfunction


""
" Get the global tasks dictionary.
""
function! tasks#global(reload) abort
    if !a:reload && has_key(g:tasks, 'global') && !g:tasks.global.invalidated
        return g:tasks.global
    endif
    let f = s:get_global_ini()
    if !filereadable(f)
        return {}
    endif
    let g:tasks.global = tasks#parse#do(readfile(f), 0)
    return g:tasks.global
endfunction


" TODO: :Project, :Compile commands
" TODO: test environmental variables expansion
" TODO: assign score to commands to see which one should be chosen
" TODO: cwd, prjname
" TODO: success/fail hooks



"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Run task
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Main command to run a task. Will call async#cmd.
""
function! tasks#run(args) abort
    redraw
    let prj = tasks#get()
    if empty(prj)
        let root = s:find_root()
        if s:change_root(root)
            lcd `=root`
            let prj = tasks#get()
        endif
    endif
    if s:no_tasks(prj)
        return
    endif
    let tasks = prj.tasks
    let a = split(a:args)
    let name = a[0]
    let args = len(a) > 1 ? join(a[1:]) : ''

    if !has_key(tasks, name)
        echon s:ut.badge() 'not a valid task'
        return
    endif

    let task = tasks[name]
    let cmd = s:choose_command(task)

    let mode = s:get_cmd_mode(task)
    let opts = extend(s:get_pos(mode),
                \     s:get_opts(get(task.fields, 'options', [])))
    let useropts = extend({
                \ 'prg': cmd,
                \ 'gprg': cmd,
                \ 'efm': get(task.fields, 'efm', &errorformat),
                \ 'compiler': get(task.fields, 'compiler', ''),
                \ 'ft': get(task.fields, 'syntax', ''),
                \}, opts)
    let jobopts = {
                \ 'env': prj.env,
                \ 'cwd': s:get_cwd(task),
                \}
    let mode = substitute(mode, ':.*', '', '')
    if mode == 'quickfix'
        call async#qfix(args, useropts, jobopts)
    else
        call async#cmd(cmd . ' ' . args, mode, useropts, jobopts)
    endif
endfunction

""
" Choose the most appropriate command for the task.
""
function! s:choose_command(task) abort
    let [cmdpat, cmppat, ft] = ['^command', '^compiler', '\<' . s:ut.ft() . '\>']

    " try 'compiler' first, then 'command'
    let cmds = filter(copy(a:task.fields), 'v:key =~ cmppat')
    if empty(cmds)
        let cmds = filter(copy(a:task.fields), 'v:key =~ cmdpat')
    endif
    " loop all the commands and choose the one with the highest score
    " score is based on specificity for system (/) and filetype (:)
    let best = [0, '']
    for cmd in keys(cmds)
        let score = (cmd =~ '/') + (cmd =~ ':')
        if score >= best[0]
            let best = [score, cmds[cmd]]
        endif
    endfor

    " clear all commands from task, the chosen command will be set instead
    call filter(a:task.fields, 'v:key !~ cmdpat')
    return best[1] != '' ? best[1] : &makeprg
endfunction

""
" If the task defines a cwd, it should be expanded.
" Expand also $ROOT and $PRJNAME because they aren't set in vim environment.
""
function! s:get_cwd(task) abort
    if has_key(a:task.fields, 'cwd')
        let cwd = async#expand(a:task.fields.cwd)
        if s:v.is_windows
            let cwd = substitute(cwd, '%\([A-Z_]\+\)%', '$\1', 'g')
        endif
        if a:task.local
            let cwd = substitute(cwd, '\$ROOT\>', '\=getcwd()', 'g')
            let cwd = substitute(cwd, '\$PRJNAME\>', '\=a:task.info.name', 'g')
        endif
        let cwd = substitute(cwd, '\(\$[A-Z_]\+\)\>', '\=expand(submatch(1))', 'g')
        return cwd
    else
        return getcwd()
    endif
endfunction

""
" Mode is either 'quickfix', 'buffer', 'terminal', 'external' or 'cmdline'.
""
function! s:get_cmd_mode(task) abort
    let mode = filter(copy(a:task.fields), { k,v -> k =~ '^output' })
    return len(mode) > 0 ? values(mode)[0] : 'quickfix'
endfunction

""
" Buffer and terminal modes can define position after ':'
""
function! s:get_pos(mode) abort
    if a:mode !~ '\v^(buffer|terminal):'.s:v.pospat
        return {}
    else
        return {'pos': substitute(a:mode, '^\w\+:', '', '')}
    endif
endfunction

""
" All options have a default of 0.
" Options defined in the 'options' field will be set to 1.
""
function! s:get_opts(opts) abort
    let opts = {}
    for v in a:opts
        let opts[v] = 1
    endfor
    return opts
endfunction

""
" Command line completion for tasks.
""
function! tasks#complete(A, C, P) abort
    let valid = keys(get(tasks#get(), 'tasks', {}))
    return filter(sort(valid), 'v:val=~#a:A')
endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" List tasks
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Display tasks in the command line, or in json format.
""
function! tasks#list(as_json) abort
    let prj = tasks#get()
    if s:no_tasks(prj)
        return
    endif
    if a:as_json
        call s:tasks_as_json(prj)
        return
    endif
    call s:cmdline_bar(prj)
    echohl Comment
    echo "Task\t\t\tProfile\t\tOutput\t\tCommand"
    for t in keys(prj.tasks)
        echohl Constant
        echo t . repeat(' ', 24 - strlen(t))
        echohl String
        let p = prj.tasks[t].local ? prj.tasks[t].profile : 'global'
        echon p . repeat(' ', 16 - strlen(p))
        echohl PreProc
        let out = split(get(prj.tasks[t].fields, 'output', 'quickfix'), ':')[0]
        echon out . repeat(' ', 16 - strlen(out))
        echohl None
        let cmd = s:choose_command(prj.tasks[t])
        let n = &columns - 66 < strlen(cmd) ? '' : 'n'
        exe 'echo' . n string(cmd)
    endfor
    echohl None
endfunction

""
" Top bar for command-line tasks list.
""
function! s:cmdline_bar(prj) abort
    echohl NonText
    let header = has_key(a:prj, 'info') ?
                \'Project: '. a:prj.info.name : 'Global tasks'
    let right   = repeat('█', &columns - 10 - strlen(header))
    echo '███'
    echohl Pmenu
    echon '   ' . header . '   '
    echohl NonText
    echon right
endfunction

""
" Display tasks in a buffer, in json format.
""
function! s:tasks_as_json(prj) abort
    let py =        executable('python3') ? 'python3'
                \ : executable('python')  ? 'python' : ''
    if py == ''
        echon s:ut.badge() 'no python executable found in $PATH'
        return
    endif
    let [ft, f] = [&ft, @%]
    let json = json_encode(a:prj)
    vnew +setlocal\ bt=nofile\ bh=wipe\ noswf\ nobl
    silent! XTabNameBuffer Tasks
    wincmd H
    put =json
    1d _
    exe '%!' . py . ' -m json.tool'
    setfiletype json
    let &l:statusline = '%#PmenuSel# Tasks %#Pmenu# ft=' .
                \       ft . ' %#Statusline# ' . f
endfunction



"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Choose task with mapping
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Choose among available tasks (called with mapping).
""
function! tasks#choose() abort
    let i = get(g:, 'tasks_mapping_starts_at', 5)
    let prj = tasks#get()
    if s:no_tasks(prj)
        return
    endif
    let Keys = { 1: "\<F1>", 2: "\<F2>", 3: "\<F3>", 4: "\<F4>",
                \5: "\<F5>", 6: "\<F6>", 7: "\<F7>", 8: "\<F8>",
                \9: "\<F9>"}
    let dict = {}
    call s:cmdline_bar(prj)
    echohl Comment
    echo "Key\tTask\t\t\tProfile\t\tOutput\t\tCommand"
    for t in keys(prj.tasks)
        if s:wrong_profile(prj, prj.tasks[t])
            continue
        endif
        let dict[Keys[i]] = t
        echohl Special
        echo '<F'.i.'>' . "\t"
        echohl Constant
        echon t . repeat(' ', 24 - strlen(t))
        echohl String
        let l = prj.tasks[t].local ? prj.tasks[t].profile : 'global'
        echon l . repeat(' ', 16 - strlen(l))
        echohl PreProc
        let out = split(get(prj.tasks[t].fields, 'output', 'quickfix'), ':')[0]
        echon out . repeat(' ', 16 - strlen(out))
        echohl None
        let cmd = s:choose_command(prj.tasks[t])
        if &columns - 74 < strlen(cmd)
            let cmd = cmd[:(&columns - 74)] . '…'
        endif
        echon cmd
        let i += 1
        if i > 12
            let i = 1
        endif
    endfor
    echo ''
    let ch = getchar()
    if index(keys(dict), ch) >= 0
        exe 'Task' dict[ch]
    else
        redraw
    endif
endfunction




"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Get configuration files
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Path for the global configuration.
""
function! s:get_global_ini() abort
    if exists('s:global_ini') && s:global_ini != ''
        return s:global_ini
    endif

    let f = get(g:, 'async_taskfile_global', 'tasks.ini')
    let l:In = { dir -> filereadable(expand(dir).'/'.f) }
    let l:Is = { dir -> expand(dir).'/'.f }

    let s:global_ini = has('nvim') &&
                \ l:In(stdpath('data'))  ? l:Is(stdpath('data')) :
                \ l:In('$HOME/.vim')     ? l:Is('$HOME/.vim') :
                \ l:In('$HOME/vimfiles') ? l:Is('$HOME/vimfiles') : ''

    if s:global_ini == ''
        let dir = fnamemodify(expand($MYVIMRC), ':p:h')
        if filereadable(dir . '/' . f)
            let s:global_ini = dir . '/' . f
        endif
    endif
    return s:global_ini
endfunction

""
" Path for the project configuration.
""
function! s:get_local_ini() abort
    return get(g:, 'async_taskfile_local', '.tasks')
endfunction



"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Helpers
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" By default, global tasks are not show in projects, unless the #info section
" states otherwise. The 'allowglobal' key can be:
" - true/false (default false)
" - a list of allowed filetypes
""
function! s:can_include_global_tasks(dict) abort
    if !has_key(a:dict, 'info')
        return v:true
    endif
    let allow = get(a:dict.info, 'allowglobal', 'false')
    if match(allow, ',') > 0
        return index(split(allow, ','), s:ut.ft()) >= 0
    endif
    return allow == 'true' || allow == s:ut.ft()
endfunction

""
" If the task is project-local, task profile must match the current one.
""
function! s:wrong_profile(project, task) abort
    return a:task.local && a:project.profile != a:task.profile
endfunction

""
" No tasks available for current project/filetye
""
function! s:no_tasks(prj) abort
    if empty(a:prj) || empty(a:prj.tasks)
        echon s:ut.badge() 'no tasks'
        return v:true
    endif
    return v:false
endfunction

""
" Search recursively for a local tasks file in parent directories.
""
function! s:find_root() abort
    let dir = expand('%:p:h')
    let fname = s:get_local_ini()
    while v:true
        if filereadable(dir . '/' . fname )
            return dir
        elseif fnamemodify(dir, ':p:h:h') == dir
            break
        else
            let dir = fnamemodify(dir, ':p:h:h')
        endif
    endwhile
    return v:null
endfunction

""
" Confirm root change.
""
function! s:change_root(root) abort
    return a:root != v:null &&
                \ confirm('Change directory to ' . a:root . '?', "&Yes\n&No") == 1
endfunction





"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Script variables
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

let s:ut = tasks#util#init()
let s:v  = s:ut.Vars



"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" vim: et sw=4 ts=4 sts=4 fdm=indent fdn=1
