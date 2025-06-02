#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="cria_usuario_webdecisor.log"
echo "########################################################" | tee -a "$LOG_FILE"
echo " Criação do Usuário de Leitura Específico: chinchila_webdecisor (Não Interativo) " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"

# Define o nome do usuário fixo
usuario="chinchila_webdecisor"
echo "[INFO] Usuário a ser criado: $usuario" | tee -a "$LOG_FILE"

# Gera uma senha aleatória segura (16 caracteres alfanuméricos)
senhagerada=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
if [[ -z "$senhagerada" ]]; then
  echo "[ERRO] Falha ao gerar senha aleatória." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[INFO] Senha aleatória gerada para o usuário $usuario." | tee -a "$LOG_FILE"

# Verifica se a senha do usuário postgres foi fornecida via variável de ambiente
if [[ -z "${PGPASSWORD:-}" ]]; then
    echo "[ERRO] A senha do usuário 'postgres' não foi fornecida." | tee -a "$LOG_FILE"
    echo "Por favor, defina a variável de ambiente PGPASSWORD antes de executar o script:" | tee -a "$LOG_FILE"
    echo "Exemplo: export PGPASSWORD='supertux'" | tee -a "$LOG_FILE"
    exit 1
fi
echo "[INFO] Usando a senha do usuário 'postgres' fornecida via PGPASSWORD." | tee -a "$LOG_FILE"

# Carrega variáveis do sistema (ajuste o caminho se necessário)
if [[ -f "/etc/wildfly.conf" ]]; then
    source /etc/wildfly.conf
else
    echo "[AVISO] Arquivo /etc/wildfly.conf não encontrado. Tentando continuar sem ele." | tee -a "$LOG_FILE"
fi

# Validação das variáveis de ambiente do wildfly.conf
if [[ -z "${END_SERVIDOR:-}" || -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  echo "Erro: END_SERVIDOR ou CHINCHILA_DS_DATABASENAME não definidos. Verifique /etc/wildfly.conf ou defina as variáveis de ambiente." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[INFO] Conectando ao banco de dados $CHINCHILA_DS_DATABASENAME em $END_SERVIDOR como usuário postgres..." | tee -a "$LOG_FILE"

# Bloco PL/pgSQL para criação e permissões
# A variável PGPASSWORD já está exportada (verificação acima)
psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" <<EOF
DO \$\$
DECLARE
  usuario_fixo varchar := '$usuario';
  senha_nova varchar := '$senhagerada';
BEGIN
  -- Remove role existente (se houver)
  IF EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = usuario_fixo) THEN
     RAISE NOTICE '[INFO] Usuário % já existe. Removendo...', usuario_fixo;
     EXECUTE format('DROP ROLE %I', usuario_fixo);
     RAISE NOTICE '[INFO] Usuário % removido.', usuario_fixo;
  END IF;

  -- Cria a role com a senha gerada
  RAISE NOTICE '[INFO] Criando usuário %...', usuario_fixo;
  EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5', usuario_fixo, senha_nova);
  RAISE NOTICE '[INFO] Usuário % criado.', usuario_fixo;

  -- Concede permissões
  RAISE NOTICE '[INFO] Concedendo permissões para %...', usuario_fixo;
  EXECUTE format('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', usuario_fixo);
  EXECUTE format('ALTER DEFAULT PRIVILEGES FOR USER chinchila IN SCHEMA public GRANT SELECT ON TABLES TO %I', usuario_fixo);

  -- Permissões específicas no schema integracao_webdecisor
  EXECUTE format('GRANT USAGE ON SCHEMA integracao_webdecisor TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaocliente TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoproduto TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoidentificador TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaogrupo TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaotipo TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaofabricante TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaovendedor TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaofornecedor TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoinformacoesvenda TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaovenda TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaocompra TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaonotasfiscais TO %I', usuario_fixo);
  EXECUTE format('GRANT SELECT ON integracao_webdecisor.v_extracaoestoque TO %I', usuario_fixo);
  RAISE NOTICE '[INFO] Permissões concedidas para %.', usuario_fixo;

END
\$\$;
EOF

# Verifica se o comando psql foi bem-sucedido
if [ $? -ne 0 ]; then
    echo "[ERRO] Falha ao executar comandos SQL para criar/configurar o usuário $usuario." | tee -a "$LOG_FILE"
    # Limpa a senha da variável de ambiente em caso de erro também
    unset PGPASSWORD
    exit 1
fi

echo "[INFO] Usuário $usuario criado/atualizado e permissões concedidas no banco de dados." | tee -a "$LOG_FILE"

# --- Atualização do pg_hba.conf ---
echo "[INFO] Atualizando pg_hba.conf..." | tee -a "$LOG_FILE"

# Detecta diretório de dados e versão do PostgreSQL
PG_DATA=$(ps aux | grep -oP '^postgres .*postmaster.*-D *\K[\/\w\.-]+' \
    || ps aux | grep -oP '^postgres.*postgres .*--config-file=.*postgresql\.conf.*-D *\K[\/\w\.-]+' \
    || echo "")

if [[ -z "$PG_DATA" || ! -d "$PG_DATA" ]]; then
    echo "[ERRO] Não foi possível detectar o diretório de dados do PostgreSQL (PGDATA). Verifique se o servidor PostgreSQL está em execução e se o script tem permissão para detectá-lo." | tee -a "$LOG_FILE"
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

# Verifica se o usuário tem permissão de escrita no pg_hba.conf ou usa sudo
HBA_NEEDS_SUDO=false
if [[ ! -w "$PG_HBA_CONF" ]]; then
    echo "[INFO] Necessário sudo para modificar $PG_HBA_CONF." | tee -a "$LOG_FILE"
    HBA_NEEDS_SUDO=true
    SUDO_CMD="sudo"
else
    SUDO_CMD=""
fi

# Remove entradas antigas do usuário
echo "[INFO] Removendo entradas antigas para $usuario em $PG_HBA_CONF (usando $SUDO_CMD se necessário)" | tee -a "$LOG_FILE"
$SUDO_CMD sed -i.bak "/# Configurado por script $usuario/d" "$PG_HBA_CONF" # Remove a linha de comentário também
$SUDO_CMD sed -i "/$usuario/d" "$PG_HBA_CONF"

# Adiciona nova entrada
echo "[INFO] Adicionando nova entrada para $usuario em $PG_HBA_CONF (usando $SUDO_CMD se necessário)" | tee -a "$LOG_FILE"
AUTH_METHOD="md5"
if dpkg --compare-versions "$PG_VERSION" ge "14"; then
  AUTH_METHOD="scram-sha-256"
fi

# Adiciona um comentário para identificar a linha adicionada pelo script
COMMENT_LINE="# Configurado por script $usuario em $(date)"
NEW_HBA_LINE="host    all             $usuario        samenet                 $AUTH_METHOD"

echo "$COMMENT_LINE" | $SUDO_CMD tee -a "$PG_HBA_CONF" > /dev/null
echo "$NEW_HBA_LINE" | $SUDO_CMD tee -a "$PG_HBA_CONF" > /dev/null

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
    if !$RELOAD_CMD; then
        echo "[ERRO] Falha ao recarregar a configuração do PostgreSQL. Verifique os logs do sistema." | tee -a "$LOG_FILE"
    else
        echo "[INFO] Configuração do PostgreSQL recarregada." | tee -a "$LOG_FILE"
    fi
else
    echo "[AVISO] Não foi possível determinar o comando para recarregar o PostgreSQL. Faça isso manually." | tee -a "$LOG_FILE"
fi

# --- Teste de Conexão e Validação --- 
echo "[INFO] Testando acesso com o usuário $usuario..." | tee -a "$LOG_FILE"
TEST_PASSED=true
# Define a senha do NOVO usuário para os testes
export PGPASSWORD_TEST="$senhagerada"

# Teste 1: SELECT na view v_extracaocliente
echo "[TESTE] Executando: SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;" | tee -a "$LOG_FILE"
if ! PGPASSWORD="$PGPASSWORD_TEST" psql -X -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;" > /dev/null 2> erro_teste1.log; then
  echo "❌ Falha no teste 1 (v_extracaocliente)! Verifique permissões e a view." | tee -a "$LOG_FILE"
  cat erro_teste1.log | tee -a "$LOG_FILE"
  TEST_PASSED=false
else
  echo "✅ Teste 1 (v_extracaocliente) OK." | tee -a "$LOG_FILE"
fi
rm -f erro_teste1.log

# Teste 2: SELECT na tabela unidademedida
echo "[TESTE] Executando: SELECT * FROM unidademedida LIMIT 1;" | tee -a "$LOG_FILE"
if ! PGPASSWORD="$PGPASSWORD_TEST" psql -X -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM unidademedida LIMIT 1;" > /dev/null 2> erro_teste2.log; then
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
  echo "✅ SUCESSO! Usuário $usuario criado/atualizado e acesso validado." | tee -a "$LOG_FILE"
  echo "########################################################" | tee -a "$LOG_FILE"
  echo "Usuário: $usuario" | tee -a "$LOG_FILE"
  echo "Senha Gerada: $senhagerada" | tee -a "$LOG_FILE"
  echo "Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
  echo "Base: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
  echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
  echo "Porta: 5432" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Arquivo pg_hba.conf atualizado e PostgreSQL recarregado." | tee -a "$LOG_FILE"
  echo "Testes de SELECT em 'integracao_webdecisor.v_extracaocliente' e 'unidademedida' concluídos com sucesso." | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "Guarde a senha gerada ($senhagerada) em local seguro!" | tee -a "$LOG_FILE"
else
  echo "" | tee -a "$LOG_FILE"
  echo "#############################################################" | tee -a "$LOG_FILE"
  echo "❌ FALHA! Ocorreram erros durante a criação ou validação." | tee -a "$LOG_FILE"
  echo "#############################################################" | tee -a "$LOG_FILE"
  echo "Verifique o log: $LOG_FILE" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  echo "[AVISO] Uma senha foi gerada ($senhagerada) mas o processo falhou." | tee -a "$LOG_FILE"
  # A reversão não será interativa nesta versão
  echo "[INFO] Tentando reverter criação do usuário $usuario (se ele chegou a ser criado)..." | tee -a "$LOG_FILE"
  # Re-exporta a senha do admin se ainda estiver disponível (pode ter sido unset)
  # É mais seguro pedir para definir novamente ou confiar que ainda está no ambiente
  # Para simplificar, vamos assumir que PGPASSWORD precisa ser definida novamente para rollback
  echo "[INFO] Para reverter, certifique-se que PGPASSWORD (senha do postgres) está definida e execute manualmente:" | tee -a "$LOG_FILE"
  echo "  psql -X -h \"$END_SERVIDOR\" -U postgres -d \"$CHINCHILA_DS_DATABASENAME\" -c \"DROP ROLE IF EXISTS \\\"$usuario\\\";\"" | tee -a "$LOG_FILE"
  echo "  # E remova a linha de $usuario do $PG_HBA_CONF e recarregue o postgresql" | tee -a "$LOG_FILE"
  exit 1
fi

exit 0
