#!/bin/bash

# Analisador de Servidor Linux v2

# --- Configurações (Ajuste conforme necessário) ---
WILDFLY_BIN_DIR="/usr/wildfly/bin"
PGSQL_LOG_DIR="/var/lib/pgsql/14/data/pg_log"
PGSQL_LOG_PATTERN="postgresql-*"

# --- Identificação de Discos ---
echo "### Dispositivos de Bloco Detectados ###"
lsblk -d -o NAME,TYPE,SIZE,MODEL | grep 'disk'

echo "
# Tentando identificar discos para análise SMART..."
# Lista discos (sda, sdb, nvme0n1, etc.) ignorando partições e loops
DISKS=$(lsblk -d -n -o NAME,TYPE | grep 'disk' | awk '{print $1}')

if [ -z "$DISKS" ]; then
  echo "Nenhum disco físico encontrado para análise SMART."
fi

echo "Discos encontrados para possível análise SMART: $DISKS"

# --- Análise SMART ---
echo "
### Análise SMART ###"

# Verifica se smartctl está instalado
if ! command -v smartctl &> /dev/null; then
    echo "Erro: smartctl não encontrado. Tentando instalar..."
    # Tenta instalar baseado no gerenciador de pacotes
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y smartmontools
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y smartmontools
    elif command -v yum &> /dev/null; then
        sudo yum install -y smartmontools
    else
        echo "Gerenciador de pacotes não suportado (apt, dnf, yum). Instale smartmontools manualmente."
    fi
    # Verifica novamente após tentativa de instalação
    if ! command -v smartctl &> /dev/null; then
       echo "Falha ao instalar smartmontools. Verifique a instalação manual."
    fi
fi

# Cria um array para armazenar a saída SMART de cada disco
declare -A SMART_DATA

if command -v smartctl &> /dev/null; then
    echo "Iniciando análise SMART para cada disco..."
    for disk in $DISKS; do
        DEVICE_PATH="/dev/$disk"
        echo "
--- Analisando $DEVICE_PATH ---"

        # Verifica se o dispositivo existe
        if [ ! -b "$DEVICE_PATH" ]; then
            echo "Dispositivo $DEVICE_PATH não encontrado. Pulando."
            continue
        fi

        # Executa smartctl e captura a saída
        SMART_OUTPUT=$(sudo smartctl -a "$DEVICE_PATH" 2>&1)
        SMART_EXIT_CODE=$?

        if [ $SMART_EXIT_CODE -ne 0 ]; then
            echo "Falha ao executar smartctl para $DEVICE_PATH. Código de saída: $SMART_EXIT_CODE"
            echo "Saída do erro (pode indicar que SMART não está habilitado ou suportado):"
            echo "$SMART_OUTPUT"
            SMART_DATA["$disk"]="ERRO: Falha ao coletar dados SMART (código $SMART_EXIT_CODE)"
        else
            echo "Coleta SMART para $DEVICE_PATH concluída."
            SMART_DATA["$disk"]="$SMART_OUTPUT"
        fi
    done
else
    echo "smartctl não está disponível. Pulando análise SMART."
fi

# --- Validação dos Dados SMART (Incluindo UDMA_CRC e ECC) ---
echo "
### Validação dos Dados SMART ###"

for disk in "${!SMART_DATA[@]}"; do
    echo "
--- Validando SMART para /dev/$disk ---"
    OUTPUT=${SMART_DATA[$disk]}

    if [[ "$OUTPUT" == ERRO:* ]]; then
        echo "$OUTPUT"
        continue
    fi

    # Campos comuns ou NVMe específicos
    if [[ "$disk" == nvme* ]]; then
        MODEL=$(echo "$OUTPUT" | grep -E '^Model Number:' | sed 's/^Model Number:[[:space:]]*//')
        AVAILABLE_SPARE=$(echo "$OUTPUT" | grep -E '^Available Spare:' | sed 's/^Available Spare:[[:space:]]*//')
        PERCENTAGE_USED=$(echo "$OUTPUT" | grep -E '^Percentage Used:' | sed 's/^Percentage Used:[[:space:]]*//')
        POWER_ON=$(echo "$OUTPUT" | grep -E '^Power On Hours:' | sed 's/^Power On Hours:[[:space:]]*//')
        ERROR_LOG_ENTRIES=$(echo "$OUTPUT" | grep -E '^Number of Error Info Log Entries:' | sed 's/^Number of Error Info Log Entries:[[:space:]]*//')

        echo "  Device Model: ${MODEL:-N/A}"
        echo "  Available Spare: ${AVAILABLE_SPARE:-N/A}"
        echo "  Percentage Used: ${PERCENTAGE_USED:-N/A}"
        echo "  Power On Hours: ${POWER_ON:-N/A}"
        echo "  Error Log Entries: ${ERROR_LOG_ENTRIES:-N/A}"
    else
        # Campos HDD/SSD
        MODEL=$(echo "$OUTPUT" | grep -E '^Device Model:' | sed 's/^Device Model:[[:space:]]*//')
        REALLOCATED=$(echo "$OUTPUT" | grep -E '^[[:space:]]*5[[:space:]]+Reallocated_Sector_Ct' | awk '{print $10}')
        POWER_ON=$(echo "$OUTPUT" | grep -E '^[[:space:]]*9[[:space:]]+Power_On_Hours' | awk '{print $10}')
        PENDING=$(echo "$OUTPUT" | grep -E '^[[:space:]]*197[[:space:]]+Current_Pending_Sector' | awk '{print $10}')
        UDMA_CRC=$(echo "$OUTPUT" | grep -E '^[[:space:]]*199[[:space:]]+UDMA_CRC_Error_Count' | awk '{print $10}')
        ECC_RECOVERED=$(echo "$OUTPUT" | grep -E '^[[:space:]]*195[[:space:]]+Hardware_ECC_Recovered' | awk '{print $10}') # ID pode variar
        ERROR_LOG_VER=$(echo "$OUTPUT" | grep -E '^SMART Error Log Version:' | sed 's/^SMART Error Log Version:[[:space:]]*//')

        echo "  Device Model: ${MODEL:-N/A}"
        echo "  Reallocated_Sector_Ct (Value): ${REALLOCATED:-N/A}"
        echo "  Power_On_Hours (Value): ${POWER_ON:-N/A}"
        echo "  Current_Pending_Sector (Value): ${PENDING:-N/A}"
        echo "  UDMA_CRC_Error_Count (Value): ${UDMA_CRC:-N/A}" # Adicionado
        echo "  Hardware_ECC_Recovered (Value): ${ECC_RECOVERED:-N/A}" # Adicionado (ID 195 é comum, mas pode variar)
        echo "  SMART Error Log Version: ${ERROR_LOG_VER:-N/A}"
    fi
done

# --- Informações da CPU e Load Average ---
echo "
### Informações da CPU e Load Average ###"
if command -v lscpu &> /dev/null; then
    lscpu | grep -E '^(Model name|CPU\(s\)|Core\(s\) per socket|Socket\(s\)|Thread\(s\) per core|Architecture|CPU max MHz|CPU min MHz|Vendor ID)'
else
    echo "Comando lscpu não encontrado."
fi
if command -v uptime &> /dev/null; then
    echo ""
    uptime # Adicionado para Load Average
else
    echo "Comando uptime não encontrado."
fi

# --- Informações de Memória RAM ---
echo "
### Informações de Memória RAM ###"
if command -v free &> /dev/null; then
    free -h
else
    echo "Comando free não encontrado."
fi

# --- Histórico de Desligamentos/Reinicializações ---
echo "
### Histórico Recente de Desligamentos/Reinicializações (últimos 20) ###"
if command -v last &> /dev/null; then
    sudo last -F -n20 -x shutdown reboot
else
    echo "Comando last não encontrado."
fi

# --- Verificação de Erros Wildfly ---
echo "
### Verificação de Erros Wildfly (hs_err) ###"
if [ -d "$WILDFLY_BIN_DIR" ]; then
    echo "Verificando erros em: $WILDFLY_BIN_DIR"
    HS_ERR_FILES=$(ls -1 "$WILDFLY_BIN_DIR"/hs_err* 2>/dev/null)
    if [ -z "$HS_ERR_FILES" ]; then
        echo "Nenhum arquivo hs_err encontrado."
    else
        echo "Arquivos hs_err encontrados:"
        ls -lsth "$WILDFLY_BIN_DIR"/hs_err*
    fi
else
    echo "Diretório Wildfly não encontrado: $WILDFLY_BIN_DIR. Pulando verificação."
fi

# --- Verificação de Logs PostgreSQL (Segmentation Fault) ---
echo "
### Verificação de Logs PostgreSQL (Segmentation Fault) ###"
if [ -d "$PGSQL_LOG_DIR" ]; then
    echo "Verificando logs em: $PGSQL_LOG_DIR ($PGSQL_LOG_PATTERN)"
    # Navega para o diretório para simplificar o grep
    cd "$PGSQL_LOG_DIR" || {
        echo "Erro ao acessar o diretório $PGSQL_LOG_DIR"
        cd -
        SEGMENTATION_ERRORS="ERRO: Não foi possível acessar $PGSQL_LOG_DIR"
    }
    if [ -z "$SEGMENTATION_ERRORS" ]; then # Só executa se o cd funcionou
        SEGMENTATION_ERRORS=$(grep "Segmentation" $PGSQL_LOG_PATTERN 2>/dev/null | cut -d':' -f1 | uniq -dc)
        if [ -z "$SEGMENTATION_ERRORS" ]; then
            echo "Nenhum erro de segmentação encontrado nos logs $PGSQL_LOG_PATTERN."
        else
            echo "ERROS DE SEGMENTAÇÃO ENCONTRADOS (Contagem Arquivo):"
            echo "$SEGMENTATION_ERRORS"
        fi
        # Retorna ao diretório anterior
        cd -
    else
        echo "$SEGMENTATION_ERRORS"
    fi
else
    echo "Diretório de logs do PostgreSQL não encontrado: $PGSQL_LOG_DIR. Pulando verificação."
fi

echo "
### Análise Concluída ###"


