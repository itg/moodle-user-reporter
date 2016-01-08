#!/bin/sh
PATH=/usr/local/bin:/usr/local/sbin:~/bin:/usr/bin:/bin:/usr/sbin:/sbin
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

cd ~/Source/moodle-user-reporter && ruby prototype.rb

