#!/bin/sh
# Rend au pool LVM-thin les blocs liberes dans chaque CT en marche
for id in $(pct list | awk "NR>1 && \$2==\"running\" {print \$1}"); do
    pct fstrim "$id"
done
