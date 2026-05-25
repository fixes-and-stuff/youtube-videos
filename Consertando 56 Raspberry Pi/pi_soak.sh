#!/usr/bin/env bash
set -euo pipefail

DUR_CPU="${DUR_CPU:-5m}"
DUR_RAM="${DUR_RAM:-5m}"
DUR_IO="${DUR_IO:-5m}"
DUR_COMBO="${DUR_COMBO:-15m}"
SAMPLE_SEC="${SAMPLE_SEC:-5}"

# Opcional: defina IPERF_SERVER=<ip_do_pc> para testar rede
IPERF_SERVER="${IPERF_SERVER:-192.168.0.4}"

TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="$HOME/pi_soak_$TS"
mkdir -p "$OUTDIR"

echo "Logs em: $OUTDIR"

# Info do sistema
{
  echo "=== DATE ==="; date
  echo "=== UNAME ==="; uname -a
  echo "=== CPUINFO ==="; grep -E 'Model|Hardware|Revision|Serial' /proc/cpuinfo || true
  echo "=== MEM ==="; free -h
  echo "=== DISK ==="; df -hT
  echo "=== VCGENCMD VERSION ==="; vcgencmd version || true
  echo "=== THROTTLED (START) ==="; vcgencmd get_throttled || true
  echo "=== CLOCKS (START) ==="; vcgencmd measure_clock arm || true
  echo "=== TEMP (START) ==="; vcgencmd measure_temp || true
} | tee "$OUTDIR/info.txt" >/dev/null

# Background: amostragem de temp / throttling
(
  echo "timestamp,temp_c,throttled_hex"
  while true; do
    t="$(date -Iseconds)"
    temp="$(vcgencmd measure_temp 2>/dev/null | sed -n 's/temp=\([0-9.]*\).*/\1/p')"
    thr="$(vcgencmd get_throttled 2>/dev/null | sed -n 's/throttled=\(0x[0-9a-fA-F]*\).*/\1/p')"
    echo "$t,${temp:-},${thr:-}"
    sleep "$SAMPLE_SEC"
  done
) > "$OUTDIR/telemetry.csv" &
TEL_PID=$!

# Background: dmesg ao vivo
sudo dmesg -wT > "$OUTDIR/dmesg_live.log" &
DMESG_PID=$!

cleanup() {
  kill "$TEL_PID" 2>/dev/null || true
  sudo kill "$DMESG_PID" 2>/dev/null || true
}
trap cleanup EXIT

run_step() {
  local name="$1"; shift
  echo "=== $name ===" | tee -a "$OUTDIR/steps.log"
  echo "CMD: $*" | tee -a "$OUTDIR/steps.log"
  (time "$@") 2>&1 | tee "$OUTDIR/${name}.log"
}

# 1) CPU
run_step "01_cpu" stress-ng --cpu 4 --cpu-method all --verify -t "$DUR_CPU" --metrics-brief

# 2) RAM (memtester + stress-ng vm)
# memtester precisa de sudo para travar bem a RAM disponível; use tamanho moderado para não matar o sistema
run_step "02_memtester" sudo memtester 512M 3
run_step "03_ram_vm" stress-ng --vm 2 --vm-bytes 70% --vm-method all --verify -t "$DUR_RAM" --metrics-brief

# 3) SD I/O (em /tmp para evitar encher o cartão com arquivo enorme; 1G é suficiente pra estressar)
run_step "04_sd_fio" fio --name=sd --filename="$HOME/fio.sd.test" --size=1G --rw=randrw --rwmixread=50 \
  --bs=4k --iodepth=16 --numjobs=1 --time_based --runtime="$DUR_IO" --direct=1
rm -f /tmp/fio.sd.test || true

# 4) USB I/O (se existir /mnt/usb montado)
if mountpoint -q /mnt/usb; then
  run_step "05_usb_fio" fio --name=usb --filename=/mnt/usb/fio.usb.test --size=2G --rw=write --bs=1M \
    --iodepth=4 --numjobs=1 --time_based --runtime="$DUR_IO" --direct=1
  rm -f /mnt/usb/fio.usb.test || true
else
  echo "SKIP: /mnt/usb não está montado (teste USB pulado)" | tee -a "$OUTDIR/steps.log"
fi

# 5) Rede (iperf3), se IPERF_SERVER foi definido
if [[ -n "$IPERF_SERVER" ]]; then
  run_step "06_iperf3" iperf3 -c "$IPERF_SERVER" -t 600 -P 4
else
  echo "SKIP: defina IPERF_SERVER=<ip> para testar rede com iperf3" | tee -a "$OUTDIR/steps.log"
fi

# 6) Combo (o mais “revelador”)
run_step "07_combo" stress-ng --cpu 4 --vm 2 --vm-bytes 65% --hdd 1 --hdd-bytes 2G --verify -t "$DUR_COMBO" --metrics-brief

# Final snapshot
{
  echo "=== THROTTLED (END) ==="; vcgencmd get_throttled || true
  echo "=== TEMP (END) ==="; vcgencmd measure_temp || true
  echo "=== CLOCK (END) ==="; vcgencmd measure_clock arm || true
} | tee -a "$OUTDIR/info.txt" >/dev/null

# Resumo de “red flags”
{
  echo "=== SUMMARY CHECKS ==="
  echo "-- throttled flags seen (telemetry) --"
  awk -F',' 'NR>1 && $3!="" && $3!="0x0"{print}' "$OUTDIR/telemetry.csv" | head -n 20 || true
  echo
  echo "-- dmesg highlights --"
  grep -Ei "under-voltage|throttl|mmc|I/O error|crc|timeout|reset (high-speed|SuperSpeed) USB|xHCI|ext4|read-only|segfault|oom-killer" \
    "$OUTDIR/dmesg_live.log" | tail -n 80 || true
} | tee "$OUTDIR/summary.txt" >/dev/null

echo "Concluído. Veja: $OUTDIR/summary.txt (e telemetry.csv / dmesg_live.log)"
EOF
