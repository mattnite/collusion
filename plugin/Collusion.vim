"Needs to be set on connect, MacVim overrides otherwise"
if !exists("collusion_default_nick")
    let g:collusion_default_nick = "guest"
endif

if !exists("g:collusion_default_server")
    let g:collusion_default_server = "localhost"
endif

func! s:CollusionSetColors ()
    hi CursorUser gui=bold term=bold cterm=bold
    hi Cursor1 ctermbg=DarkRed ctermfg=White guibg=DarkRed guifg=White gui=bold term=bold cterm=bold
    hi Cursor2 ctermbg=DarkBlue ctermfg=White guibg=DarkBlue guifg=White gui=bold term=bold cterm=bold
    hi Cursor3 ctermbg=DarkGreen ctermfg=White guibg=DarkGreen guifg=White gui=bold term=bold cterm=bold
    hi Cursor4 ctermbg=DarkCyan ctermfg=White guibg=DarkCyan guifg=White gui=bold term=bold cterm=bold
    hi Cursor5 ctermbg=DarkMagenta ctermfg=White guibg=DarkMagenta guifg=White gui=bold term=bold cterm=bold
    hi Cursor6 ctermbg=Brown ctermfg=White guibg=Brown guifg=White gui=bold term=bold cterm=bold
    hi Cursor7 ctermbg=LightRed ctermfg=Black guibg=LightRed guifg=Black gui=bold term=bold cterm=bold
    hi Cursor8 ctermbg=LightBlue ctermfg=Black guibg=LightBlue guifg=Black gui=bold term=bold cterm=bold
    hi Cursor9 ctermbg=LightGreen ctermfg=Black guibg=LightGreen guifg=Black gui=bold term=bold cterm=bold
    hi Cursor10 ctermbg=LightCyan ctermfg=Black guibg=LightCyan guifg=Black gui=bold term=bold cterm=bold
    hi Cursor0 ctermbg=LightYellow ctermfg=Black guibg=LightYellow guifg=Black gui=bold term=bold cterm=bold
endfunc

function MovedHandler(channel)
  let pos = getpos('.')
  call ch_sendraw(a:channel, "mov ".pos[1]." ".pos[2]."\n")
endfunction

func! Listener(bufnr, start, end, added, changes)
  if a:added < 0
    call ch_sendraw(b:channel, "del ".a:start." ".(a:end-1)."\n")
  elseif a:added == 0
    call ch_sendraw(b:channel, "chg ".a:start." ".getline(a:start)."\n")
  else
    call ch_sendraw(b:channel, "ins ".a:start." ".a:added."\n")

    for line in getline(a:start, a:start + a:added - 1)
      call ch_sendraw(b:channel, line."\n")
    endfor
  endif
endfunc

function! s:CollusionQuit ()
  call job_stop(b:job)
  call listener_remove(b:listener)
  augroup collusion_group
    au!
  augroup END
endfunction

function! s:CollusionStartJob (room, cmd, args)
  if len(a:args) == 0
    let server = g:collusion_default_server
  else
    let server = a:args[0]
  endif

  let b:job = job_start("/home/mknight/code/collusion/zig-cache/bin/collusion-client ".a:cmd." ".a:room." ".server." 9000")

  let b:channel = job_getchannel(b:job)
  let b:listener = listener_add('Listener')

  augroup collusion_group
    au CursorMoved <buffer> call MovedHandler(b:channel)
    au BufDelete <buffer> call s:CollusionQuit()
  augroup END

"  if a:cmd == "host"
"    let total = line('$')
"    call ch_sendraw(b:channel, "sync ".total."\n")
"
"    for line in getline(1, total)
"      call ch_sendraw(b:channel, line."\n")
"    endfor
"  endif
endfunc

function! s:CollusionHost (room, ...)
  call s:CollusionSetColors()
  call s:CollusionStartJob(a:room, "host", a:000)
  echo a:room
endfunction

function! s:CollusionJoin (room, ...)
  call s:CollusionSetColors()
  call s:CollusionStartJob(a:room, "join", a:000)
  echo a:room
endfunction

" Public Commands
command! -nargs=* CollusionHost :call s:CollusionHost(<args>)
command! -nargs=* CollusionJoin :call s:CollusionJoin(<args>)
command! CollusionQuit :call s:CollusionQuit()
