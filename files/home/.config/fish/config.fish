if status is-interactive
    set -g fish_greeting
    zoxide init fish | source
    starship init fish | source

    alias ls 'eza -al --color=always --group-directories-first'
    alias la 'eza -a --color=always --group-directories-first'
    alias ll 'eza -l --color=always --group-directories-first'
    alias lt 'eza -aT --color=always --group-directories-first'
    alias cat 'bat --paging=never'

    # xbps with a snapper pre/post snapshot pair around every change (undo: snapper -c root undochange N..M)
    abbr xu 'sudo snapper -c root create -c number -d "xbps-install -Su" --command "xbps-install -Su"'
    function xi --description 'xbps-install inside a snapper pre/post pair'
        sudo snapper -c root create -c number -d "xbps-install $argv" --command "xbps-install -S $argv"
    end
    abbr xr 'sudo xbps-remove -R'
    abbr xq 'xbps-query -Rs'
    abbr snaps 'snapper -c root list; snapper -c home list'
    abbr ev-update 'sudo ~/enter_void/setup.sh apps'
end
