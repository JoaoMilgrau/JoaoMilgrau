#!/usr/bin/env bash

set -euo pipefail

# Define o nome do usuário fixo
usuario_fixo="chinchila_webdecisor"

# Define o arquivo de log no diretório /tmp para evitar problemas de permissão
LOG_FILE="/tmp/cria_${usuario_fixo}.log"
# Limpa o log antigo se existir
> "$LOG_FILE"

echo "########################################################" | tee -a "$LOG_FILE"
echo " Criação do Usuário de Leitura Específico: ${usuario_fixo} " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"
echo "[INFO] O log desta execução será salvo em: ${LOG_FILE}" | tee -a "$LOG_FILE"

# Solicita senha do admin postgres
read -s -p "Digite a senha do usuário postgres: " PGPASSWORD
echo
export PGPASSWORD

# Solicita senha para o novo usuário fixo
read -s -p "Digite a senha para o usuário ${usuario_fixo}: " senha_novo_usuario
echo

# Carrega variáveis do sistema (ajuste o caminho se necessário)
if [[ -f "/etc/wildfly.conf" ]]; then
    source /etc/wildfly.conf
else
    echo "[AVISO] Arquivo /etc/wildfly.conf não encontrado. Tentando continuar sem ele." | tee -a "$LOG_FILE"
fi

# Validação das variáveis de ambiente
if [[ -z "${END_SERVIDOR:-}" || -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  echo "Erro: END_SERVIDOR ou CHINCHILA_DS_DATABASENAME não definidos. Verifique /etc/wildfly.conf ou defina as variáveis de ambiente." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[INFO] Criando usuário ${usuario_fixo} no banco de dados ${CHINCHILA_DS_DATABASENAME} em ${END_SERVIDOR}..." | tee -a "$LOG_FILE"

# Bloco PL/pgSQL para criação e permissões
psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" <<EOF >> "$LOG_FILE" 2>&1
DO \$\$
DECLARE
  usuario_alvo varchar := 
'$usuario_fixo

';
  senha_alvo varchar := 
'$senha_novo_usuario

';
BEGIN
  -- Validação da senha (mínimo 4 caracteres)
  IF (length(senha_alvo) < 4) THEN
    RAISE EXCEPTION 'A senha para % deve ter no mínimo 4 caracteres', usuario_alvo;
  END IF;

  -- Remove role existente (se houver)
  RAISE NOTICE '[INFO] Verificando se o usuário % já existe...', usuario_alvo;
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = usuario_alvo) THEN
     RAISE NOTICE '[INFO] Usuário % já existe. Removendo...', usuario_alvo;
     EXECUTE format('DROP ROLE %I', usuario_alvo);
     RAISE NOTICE '[INFO] Usuário % removido.', usuario_alvo;
  END IF;

  -- Cria a role
  RAISE NOTICE '[INFO] Criando usuário %...', usuario_alvo;
  EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5', usuario_alvo, senha_alvo);
  RAISE NOTICE '[INFO] Usuário % criado.', usuario_alvo;

  -- Concede permissões
  RAISE NOTICE '[INFO] Concedendo permissões para %...', usuario_alvo;
  
  -- Permissões no schema public
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', usuario_alvo);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR USER chinchila IN SCHEMA public GRANT SELECT ON TABLES TO %I', usuario_alvo);
  RAISE NOTICE '[INFO] Permissões no schema public concedidas.', usuario_alvo;

  -- Permissões específicas no schema integracao_webdecisor
  RAISE NOTICE '[INFO] Concedendo permissões no schema integracao_webdecisor...';
  EXECUTE format('GRANT USAGE ON SCHEMA integracao_webdecisor TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaocliente TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoproduto TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoidentificador TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaogrupo TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaotipo TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaofabricante TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaovendedor TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaofornecedor TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoinformacoesvenda TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaovenda TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaocompra TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaonotasfiscais TO %I', usuario_alvo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoestoque TO %I', usuario_alvo);
  RAISE NOTICE '[INFO] Permissões no schema integracao_webdecisor concedidas.';

  RAISE NOTICE '[INFO] Todas as permissões para % foram concedidas.', usuario_alvo;

END
\$\$;
EOF

# Verifica se o comando psql foi bem-sucedido
psql_exit_code=$?
if [ $psql_exit_code -ne 0 ]; then
    echo "[ERRO] Falha ao executar comandos SQL (código de saída: $psql_exit_code). Verifique o log: $LOG_FILE" | tee -a "$LOG_FILE"
    unset PGPASSWORD # Limpa a senha do admin
    exit 1
fi

echo "[INFO] Usuário ${usuario_fixo} criado/atualizado e permissões concedidas no banco de dados." | tee -a "$LOG_FILE"

# --- Atualização do pg_hba.conf ---
echo "[INFO] Atualizando pg_hba.conf..." | tee -a "$LOG_FILE"

# Detecta diretório de dados e versão do PostgreSQL
PG_DATA=$(ps aux | grep -oP 
'^postgres .*postmaster.*-D *\K[\/\w\.-]+'
 \
    || ps aux | grep -oP 
'^postgres.*postgres .*--config-file=.*postgresql\.conf.*-D *\K[\/\w\.-]+'
 \
    || echo "")

if [[ -z "$PG_DATA" || ! -d "$PG_DATA" ]]; then
    echo "[ERRO] Não foi possível detectar o diretório de dados do PostgreSQL (PGDATA). Verifique se o servidor PostgreSQL está em execução." | tee -a "$LOG_FILE"
    unset PGPASSWORD
    exit 1
fi
echo "[INFO] Diretório de dados detectado: $PG_DATA" | tee -a "$LOG_FILE"

if [[ ! -f "$PG_DATA/PG_VERSION" ]]; then
    echo "[ERRO] Arquivo PG_VERSION não encontrado em $PG_DATA." | tee -a "$LOG_FILE"
    unset PGPASSWORD
    exit 1
fi
PG_VERSION=$(cat "$PG_DATA/PG_VERSION")
PG_HBA_CONF="$PG_DATA/pg_hba.conf"
echo "[INFO] Versão do PostgreSQL detectada: $PG_VERSION" | tee -a "$LOG_FILE"
echo "[INFO] Arquivo de configuração de autenticação: $PG_HBA_CONF" | tee -a "$LOG_FILE"

if [[ ! -f "$PG_HBA_CONF" ]]; then
    echo "[ERRO] Arquivo pg_hba.conf não encontrado em $PG_DATA." | tee -a "$LOG_FILE"
    unset PGPASSWORD
    exit 1
fi

# Verifica se precisa de sudo para editar pg_hba.conf
SUDO_CMD=""
if [[ ! -w "$PG_HBA_CONF" ]]; then
    echo "[INFO] Necessário sudo para modificar $PG_HBA_CONF." | tee -a "$LOG_FILE"
    SUDO_CMD="sudo"
fi

# Remove entradas antigas do usuário
echo "[INFO] Removendo entradas antigas para ${usuario_fixo} em $PG_HBA_CONF (usando $SUDO_CMD se necessário)" | tee -a "$LOG_FILE"
$SUDO_CMD sed -i.bak "/# Configurado por script ${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
$SUDO_CMD sed -i "/${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1

# Adiciona nova entrada
echo "[INFO] Adicionando nova entrada para ${usuario_fixo} em $PG_HBA_CONF (usando $SUDO_CMD se necessário)" | tee -a "$LOG_FILE"
AUTH_METHOD="md5"
if dpkg --compare-versions "$PG_VERSION" ge "14" &>/dev/null; then
  AUTH_METHOD="scram-sha-256"
fi

COMMENT_LINE="# Configurado por script ${usuario_fixo} em $(date)"
NEW_HBA_LINE="host    all             ${usuario_fixo}        samenet                 $AUTH_METHOD"

# Usar tee com sudo para adicionar linhas ao arquivo protegido
echo "$COMMENT_LINE" | $SUDO_CMD tee -a "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
echo "$NEW_HBA_LINE" | $SUDO_CMD tee -a "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1

# Recarrega configuração do PostgreSQL (requer sudo)
echo "[INFO] Recarregando configuração do PostgreSQL (Versão $PG_VERSION)..." | tee -a "$LOG_FILE"
RELOAD_CMD=""
if command -v systemctl &> /dev/null && systemctl is-active postgresql &> /dev/null; then
    RELOAD_CMD="sudo systemctl reload postgresql"
elif command -v service &> /dev/null;
    then
    if service "postgresql-$PG_VERSION" status &> /dev/null; then
        RELOAD_CMD="sudo service postgresql-$PG_VERSION reload"
    elif service postgresql status &> /dev/null; then
        RELOAD_CMD="sudo service postgresql reload"
    fi
fi

if [[ -n "$RELOAD_CMD" ]]; then
    echo "[INFO] Executando: $RELOAD_CMD" | tee -a "$LOG_FILE"
    if !$RELOAD_CMD >> "$LOG_FILE" 2>&1; then
        echo "[ERRO] Falha ao recarregar a configuração do PostgreSQL. Verifique os logs do sistema e o log: $LOG_FILE" | tee -a "$LOG_FILE"
    else
        echo "[INFO] Configuração do PostgreSQL recarregada." | tee -a "$LOG_FILE"
    fi
else
    echo "[AVISO] Não foi possível determinar o comando para recarregar o PostgreSQL. Faça isso manualmente." | tee -a "$LOG_FILE"
fi

# --- Teste de Conexão e Validação --- 
echo "[INFO] Testando acesso com o usuário ${usuario_fixo}..." | tee -a "$LOG_FILE"
TEST_PASSED=true
export PGPASSWORD_TEST="$senha_novo_usuario" # Define a senha do NOVO usuário para os testes

# Teste 1: SELECT na view v_extracaocliente
echo "[TESTE] Executando: SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;" | tee -a "$LOG_FILE"
if ! PGPASSWORD="$PGPASSWORD_TEST" psql -X -h "$END_SERVIDOR" -U "$usuario_fixo" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;" >> "$LOG_FILE" 2> erro_teste1.log; then
  echo "❌ Falha no teste 1 (v_extracaocliente)! Verifique permissões e a view." | tee -a "$LOG_FILE"
  cat erro_teste1.log | tee -a "$LOG_FILE"
  TEST_PASSED=false
else
  echo "✅ Teste 1 (v_extracaocliente) OK." | tee -a "$LOG_FILE"
fi
rm -f erro_teste1.log

# Teste 2: SELECT na tabela unidademedida
echo "[TESTE] Executando: SELECT * FROM unidademedida LIMIT 1;" | tee -a "$LOG_FILE"
if ! PGPASSWORD="$PGPASSWORD_TEST" psql -X -h "$END_SERVIDOR" -U "$usuario_fixo" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM unidademedida LIMIT 1;" >> "$LOG_FILE" 2> erro_teste2.log; then
  echo "❌ Falha no teste 2 (unidademedida)! Verifique permissões e a tabela." | tee -a "$LOG_FILE"
  cat erro_teste2.log | tee -a "$LOG_FILE"
  TEST_PASSED=false
else
  echo "✅ Teste 2 (unidademedida) OK." | tee -a "$LOG_FILE"
fi
rm -f erro_teste2.log

# Limpa as senhas das variáveis de ambiente
unset PGPASSWORD
unset PGPASSWORD_TEST

# Resultado Final
if $TEST_PASSED; then
  echo "" | tee -a "$LOG_FILE"
  echo "########################################################" | tee -a "$LOG_FILE"
  echo "✅ SUCESSO! Usuário ${usuario_fixo} criado/atualizado e acesso validado." | tee -a "$LOG_FILE"
  echo "########################################################" | tee -a "$LOG_FILE"
  echo "Usuário: ${usuario_fixo}" | tee -a "$LOG_FILE"
  echo "Senha: (a senha que você digitou para ${usuario_fixo})" | tee -a "$LOG_FILE"
  echo "Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
  echo "Base: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
  echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
  echo "Porta: 5432" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Arquivo pg_hba.conf atualizado e PostgreSQL recarregado." | tee -a "$LOG_FILE"
  echo "Testes de SELECT em 'integracao_webdecisor.v_extracaocliente' e 'unidademedida' concluídos com sucesso." | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Log completo disponível em: ${LOG_FILE}" | tee -a "$LOG_FILE"
  read -p "Pressione ENTER para encerrar..."

else
  echo "" | tee -a "$LOG_FILE"
  echo "#############################################################" | tee -a "$LOG_FILE"
  echo "❌ FALHA! Ocorreram erros durante a criação ou validação." | tee -a "$LOG_FILE"
  echo "#############################################################" | tee -a "$LOG_FILE"
  echo "Verifique o log: $LOG_FILE" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  read -p "Deseja tentar reverter a criação do usuário ${usuario_fixo}? [s/N]: " resposta

  if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "[INFO] Tentando reverter criação do usuário ${usuario_fixo}..." | tee -a "$LOG_FILE"
    # Re-pede a senha do admin para o rollback
    read -s -p "Digite a senha do usuário postgres para reverter: " PGPASSWORD_ROLLBACK
    echo
    export PGPASSWORD="$PGPASSWORD_ROLLBACK"
    
    psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" -c "DROP ROLE IF EXISTS \"${usuario_fixo}\";" >> "$LOG_FILE" 2>&1
    echo "[INFO] Removendo entrada de ${usuario_fixo} do pg_hba.conf (se adicionada)..." | tee -a "$LOG_FILE"
    if [[ -n "$SUDO_CMD" ]]; then
        $SUDO_CMD sed -i.bak "/# Configurado por script ${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
        $SUDO_CMD sed -i "/${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
    else
        sed -i.bak "/# Configurado por script ${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
        sed -i "/${usuario_fixo}/d" "$PG_HBA_CONF" >> "$LOG_FILE" 2>&1
    fi
    echo "[INFO] Recarregando PostgreSQL..." | tee -a "$LOG_FILE"
    if [[ -n "$RELOAD_CMD" ]]; then
        $RELOAD_CMD >> "$LOG_FILE" 2>&1
    else
        echo "[AVISO] Recarregue o PostgreSQL manualmente." | tee -a "$LOG_FILE"
    fi
    unset PGPASSWORD
    echo "Rollback tentado. Verifique o status e o log: $LOG_FILE" | tee -a "$LOG_FILE"
  else
    echo "" | tee -a "$LOG_FILE"
    echo "⚠️ ATENÇÃO: Processo finalizado com falhas. Nenhuma reversão automática foi realizada." | tee -a "$LOG_FILE"
    echo "Verifique o log $LOG_FILE para detalhes dos erros." | tee -a "$LOG_FILE"
  fi
  exit 1
fi

exit 0
