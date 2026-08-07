#!/bin/zsh
set -u
HERE=${0:a:h}
PJSUA=${PJSUA:-$HERE/../../../pjproject/pjsip-apps/bin/pjsua-$(cd "$HERE/../../../pjproject" && make infotarget 2>/dev/null | tail -1)}
cd "$HERE" || exit 1
rm -f registrar-norequire.log pjsua-norequire.log
swift RegistrarNoRequire.swift > registrar-norequire.log 2>&1 &
REG_PID=$!
sleep 3
# reg-timeout 40 so the refresh (~36s) lands well inside the run.
(sleep 130; echo q) | "$PJSUA" \
    --null-audio --no-udp --local-port=50080 \
    --id "sip:a@127.0.0.1" \
    --registrar "sip:127.0.0.1:50070;transport=tcp" \
    --username a --password x --realm '*' \
    --reg-timeout 40 --log-level 4 \
    > pjsua-norequire.log 2>&1
kill $REG_PID 2>/dev/null; wait $REG_PID 2>/dev/null
echo done
