#!/bin/zsh
# A UDP account never advertises outbound, so a 439 to it is non-conformant.
# With the reg_contact gate, pjsua must NOT disable outbound and must NOT retry:
# expect exactly ONE REGISTER. Without the gate it retries once (~55s), giving two.
set -u
HERE=${0:a:h}
PJSUA=${PJSUA:-$HERE/../../../pjproject/pjsip-apps/bin/pjsua-$(cd "$HERE/../../../pjproject" && make infotarget 2>/dev/null | tail -1)}

cd "$HERE" || exit 1
rm -f registrar-udp.log pjsua-439-udp.log

swift Registrar439UDP.swift > registrar-udp.log 2>&1 &
REG_PID=$!
sleep 3

# Wait past reg_first_retry_interval (~55s) so a retry, if any, is observed.
(sleep 90; echo q) | "$PJSUA" \
    --null-audio --no-tcp --local-port=50080 \
    --id "sip:a@127.0.0.1" \
    --registrar "sip:127.0.0.1:50070" \
    --username a --password x --realm '*' \
    --reg-timeout 300 --log-level 4 \
    > pjsua-439-udp.log 2>&1

wait $REG_PID 2>/dev/null
echo "done"
