" ========================================================================###
" Description: parse global/project-local configuration files
" File:        parse.vim
" Author:      Gianmaria Bajo <mg1979@git.gmail.com>
" License:     MIT
" Created:     sab 21 novembre 2020 11:46:08
" Modified:    sab 21 novembre 2020 11:46:08
" ========================================================================###

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Configuration files
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Tasks can be defined at global level or per project. Project-local tasks
" override global tasks with the same name.
"
" When one tries to run a task, the global file and the local file are parsed
" and merged. The parsed tasks are stored in the global table g:tasks.
"
" The g:tasks table has the following structure:
"
"   g:tasks = {
"     global = {
"         tasks,        DICT
"     },
"     project_1 = {
"         env,          DICT
"         tasks,        DICT
"         profile,      STRING
"     },
"     ...
"   }
"
" No profile can be defined for the global tasks. It's a project thing.
" Elements in x.tasks have the following structure:
"
"   taskname = {
"     local,            BOOL
"     fields,           DICT
"     profile,          STRING
"     warnings,         LIST        TODO
"   }
"
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Parse configuration files
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Function: tasks#parse#do
" Parse and validate a tasks config file.
" @param lines:    lines of the tasks file
" @param is_local: true if it's project-local tasks file
""
function! tasks#parse#do(lines, is_local, ignore_profiles) abort
    if empty(a:lines)
        return {}
    endif
    let p = s:new_config(a:is_local)
    let l:NewSection = function('tasks#task#new', [p, a:is_local])
    let current = v:null

    for line in a:lines
        if match(line, '^;') == 0 || empty(line)
            continue

        elseif match(line, s:envsect) == 0 && a:is_local
            let current = l:NewSection('__env__')

        elseif match(line, s:infosect) == 0 && a:is_local
            let current = l:NewSection('__info__')

        elseif match(line, s:tasksect) == 1
            " before creating a task, we check the profile compatibility,
            " or we could overwrite an existing task with a bad one
            " if the profile is wrong, ignore the section's fields
            let profile = s:get_profile(line)
            if !a:ignore_profiles && s:wrong_profile(profile)
                let current = v:null
                continue
            endif
            let current = l:NewSection(matchstr(line, s:tasksect))
            let current.profile = profile

        elseif current isnot v:null
            for pat in values(current.patterns)
                if match(line, pat) == 0
                    let item = matchstr(line, pat)
                    let current.fields[item] = substitute(line, item . '=', '', '')
                    break
                endif
            endfor
        endif
    endfor
    call filter(p.tasks, { k,v -> v.validate(p,k)})
    call s:update_prjname(p, a:is_local)
    return s:rename_tasks(p)
endfunction


""
" If the task is project-local, task profile must match the current one.
""
function! s:get_profile(line) abort
    return a:line =~ s:profpat ? matchstr(a:line, s:profpat) : 'default'
endfunction



""
" If the task is project-local, task profile must match the current one.
""
function! s:wrong_profile(profile) abort
    return g:tasks['__profile__'] !=# a:profile
endfunction



"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Helpers
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

""
" Constructor for project/global configuration.
""
function! s:new_config(local) abort
    let p = { 'tasks': {}, 'env': {} }
    if a:local
        let p.env = { 'ROOT': getcwd(), 'PRJNAME': s:ut.basedir() }
        let p.info = { 'name': s:ut.basedir() }
    endif
    return p
endfunction

""
" Strip the conditions modifiers from the task name.
""
function! s:task_name(taskname) abort
    let tn = a:taskname
    if match(tn, '/') > 0
        let tn = split(tn, '/')[0]
    endif
    return tn
endfunction

""
" Update the PRJNAME env variable to match the project's name.
""
function! s:update_prjname(prj, local) abort
    if a:local
        let a:prj.env['PRJNAME'] = a:prj.info.name
    endif
endfunction

""
" Remove modifiers from task names.
""
function! s:rename_tasks(prj) abort
    let renamed_tasks = {}
    for t in keys(a:prj.tasks)
        let rt = s:task_name(t)
        if t != rt
            let renamed_tasks[rt] = remove(a:prj.tasks, t)
        endif
    endfor
    call extend(a:prj.tasks, renamed_tasks)
    return a:prj
endfunction


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Script variables
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
let s:profpat  = '\v]\s+\@\zs\w+'

let s:tasksect = '\v^\[\zs\.?(\w+-?\w+)+(\/(\w+,?)+)?\ze](\s+\@\w+)?$'
let s:envsect  = '^#\(\<env\>\|\<environment\>\)$'
let s:infosect = '^#info$'

let s:ut = tasks#util#init()
let s:v  = s:ut.Vars




"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" vim: et sw=4 ts=4 sts=4 fdm=indent fdn=1
