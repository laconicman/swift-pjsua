#!/bin/zsh
# usage: run-scripted.sh <scenario> [pjsua-binary] [label]
#
# Runs one RegistrarScripted.swift scenario against pjsua. Ports derive from
# the scenario and the label ("base" gets its own), so a patched build and a
# baseline build can run the same scenario in parallel:
#   ./run-scripted.sh active-then-na &
#   ./run-scripted.sh active-then-na /path/to/baseline/pjsua base &
set -u
HERE=${0:a:h}
SCEN=$1
PJSUA=${2:-$HERE/../../../pjproject/pjsip-apps/bin/pjsua-$(cd "$HERE/../../../pjproject" && make infotarget 2>/dev/null | tail -1)}
LABEL=${3:-run}
SCENARIOS=(norequire active-then-na failover-439 initial-439 nat-rewrite nat-rewrite-401)
IDX=${SCENARIOS[(i)$SCEN]}
(( IDX <= ${#SCENARIOS} )) || { echo "unknown scenario: $SCEN"; exit 1; }
OFF=$([[ $LABEL == base ]] && echo 1 || echo 0)
RPORT=$((51000 + IDX * 10 + OFF))
LPORT=$((52000 + IDX * 10 + OFF))
# The failover retry waits out reg_first_retry_interval (~60 s).
SECS=$([[ $SCEN == failover-439 ]] && echo 140 || echo 110)

# Compiled once: six interpreted registrars starting at once are slow.
BIN=${TMPDIR:-/tmp}/registrar-scripted
[[ -x $BIN && $BIN -nt $HERE/RegistrarScripted.swift ]] ||
    swiftc -O $HERE/RegistrarScripted.swift -o $BIN || exit 1

OUT=$HERE/out/$LABEL-$SCEN
mkdir -p $HERE/out
$BIN $SCEN $RPORT 3 > $OUT.registrar.log 2>&1 &
REG=$!
sleep 1
(sleep $SECS; echo q) | "$PJSUA" \
    --null-audio --no-udp --local-port=$LPORT \
    --id "sip:a@127.0.0.1" \
    --registrar "sip:127.0.0.1:$RPORT;transport=tcp" \
    --username a --password x --realm '*' \
    --reg-timeout 40 --log-level 4 \
    > $OUT.pjsua.log 2>&1
kill $REG 2>/dev/null; wait $REG 2>/dev/null
echo "$LABEL $SCEN done: $OUT.registrar.log"
