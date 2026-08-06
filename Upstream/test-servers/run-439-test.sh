#!/bin/zsh
# Live 439 (PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT) verification.
# Registrar439.swift answers any outbound REGISTER with 439 and accepts the
# retry. We inspect both REGISTERs on the wire.
set -u
HERE=${0:a:h}
PJSUA=${PJSUA:-$HERE/../../../pjproject/pjsip-apps/bin/pjsua-$(cd "$HERE/../../../pjproject" && make infotarget 2>/dev/null | tail -1)}

cd "$HERE" || exit 1
rm -f registrar.log pjsua-439.log

swift Registrar439.swift > registrar.log 2>&1 &
REG_PID=$!
sleep 3

# The first retry uses reg_first_retry_interval (~55s by default).
(sleep 95; echo q) | "$PJSUA" \
    --null-audio --no-udp --local-port=50080 \
    --id "sip:a@127.0.0.1" \
    --registrar "sip:127.0.0.1:50070;transport=tcp" \
    --username a --password x --realm '*' \
    --reg-timeout 300 --log-level 4 \
    > pjsua-439.log 2>&1

kill $REG_PID 2>/dev/null
wait $REG_PID 2>/dev/null
echo "done"
