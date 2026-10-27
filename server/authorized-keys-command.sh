#!/bin/sh

for file in /etc/ssh/authorized-keys/*.pub; do
  [ -f "$file" ] || continue
  tr -d '\r' <"$file"
  echo
done

exit 0
