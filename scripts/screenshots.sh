#!/bin/bash
# Abre o app no simulador com dados de demonstração e tira capturas de cada tela.
# Uso: scripts/screenshots.sh <udid-do-simulador> <pasta-de-saida>
set -uo pipefail
SIM="$1"
OUT="$2"
BUNDLE="br.com.colorsoftware.expediente"
APP=$(find build/Build/Products -maxdepth 2 -name "Expediente.app" -path "*iphonesimulator*" | head -1)
if [ -z "$APP" ]; then
  echo "App do simulador não encontrado; compilando…"
  xcodebuild build -project Expediente.xcodeproj -scheme Expediente -destination "id=$SIM" \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet || exit 1
  APP=$(find build/Build/Products -maxdepth 2 -name "Expediente.app" -path "*iphonesimulator*" | head -1)
fi
echo "App: $APP"

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl ui "$SIM" appearance light
xcrun simctl status_bar "$SIM" override --time "9:41" --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
[ -n "$APP" ] || { echo "Sem app para instalar"; exit 1; }
xcrun simctl install "$SIM" "$APP" || exit 1

shot() {
  local name="$1"; local screen="$2"; local wait="${3:-6}"
  xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$SIM" "$BUNDLE" -demo -screen "$screen" >/dev/null
  sleep "$wait"
  xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "ok: $name"
  # Diagnóstico: o app ainda está aberto? Se travou, guarda a pilha de chamadas.
  local pid
  pid=$(pgrep -f "/Expediente.app/Expediente" | head -1)
  if [ -z "$pid" ]; then
    echo "ATENÇÃO: o app fechou na tela $name"
    ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i expediente | head -1 | while read -r f; do
      head -120 ~/Library/Logs/DiagnosticReports/"$f" > "$OUT/../logs/crash-$name.txt"
    done
  elif [ "${SAMPLE:-}" = "$name" ]; then
    sample "$pid" 2 -file "$OUT/../logs/sample-$name.txt" >/dev/null 2>&1 || true
  fi
}

shot 01-inicio home 8
shot 02-agenda agenda
SAMPLE=03-agendar-sugestao shot 03-agendar-sugestao agendar 9
shot 04-desmarcar desmarcar 7
shot 05-remarcar remarcar 7
shot 06-clientes clientes
shot 07-cliente cliente
shot 08-historico historico
shot 09-anotacao anotacao 7
shot 10-anotacoes anotacoes
shot 11-financeiro financeiro
shot 12-pacotes pacotes
shot 13-pacote pacote
shot 14-despesas despesas
shot 15-relatorios relatorios
shot 16-notas-fiscais notas
shot 17-ajustes ajustes
shot 18-registro-de-acessos registro
shot 19-tags tags
shot 20-cadastro cadastro
shot 21-area area
shot 22-aviso-lgpd lgpd
shot 23-chave-de-recuperacao chave
shot 24-bloqueio bloqueio
shot 25-menu-de-funcoes menu 8
shot 26-agenda-semana semana 8
shot 27-agenda-mes mes 8
shot 28-retorno retorno 8
shot 29-whatsapp-sem-telefone whatsapp-sem-telefone 8
shot 30-agendar-cliente-novo agendar-cliente-novo 9
shot 31-perfil perfil
shot 32-dias-e-feriados dias-feriados
shot 33-mensagens-whatsapp mensagem-whatsapp
shot 34-pix pix
shot 35-nfse nfse 8
shot 36-nfse-ajustes nfse-ajustes
shot 37-cabecalho-e-rodape cabecalho
shot 38-certificados certificados

xcrun simctl ui "$SIM" appearance dark
shot 39-inicio-escuro home 8
shot 40-agenda-escura agenda
shot 41-semana-escura semana 8
xcrun simctl ui "$SIM" appearance light
exit 0
