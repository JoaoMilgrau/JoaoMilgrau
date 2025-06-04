#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="usuario_leitura.log"
echo "########################################################" | tee -a "$LOG_FILE"
echo "  Criação e Configuração do Usuário: chinchila_webdecisor  " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"

read -s -p "Senha do usuário postgres: " PGPASSWORD
echo
export PGPASSWORD

read -s -p "Digite a senha para o usuário chinchila_webdecisor: " senha
echo

# Carrega variáveis do sistema
source /etc/wildfly.conf

usuario="chinchila_webdecisor"

# Validação de variáveis
if [[ -z "${END_SERVIDOR:-}" || -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  echo "Erro: END_SERVIDOR ou CHINCHILA_DS_DATABASENAME não definidos." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[INFO] Criando usuário no banco de dados..." | tee -a "$LOG_FILE"

psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" <<EOF
DO \$\$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = '$usuario') THEN
    EXECUTE format('DROP ROLE %I', '$usuario');
  END IF;

  EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5', '$usuario', '$senha');

  EXECUTE 'GRANT USAGE ON SCHEMA integracao_webdecisor TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaocliente TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaoproduto TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaoidentificador TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaogrupo TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaotipo TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaofabricante TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaovendedor TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaofornecedor TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaoinformacoesvenda TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaovenda TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaocompra TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaonotasfiscais TO $usuario';
  EXECUTE 'GRANT SELECT ON integracao_webdecisor.v_extracaoestoque TO $usuario';
  EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO $usuario';
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR USER chinchila IN SCHEMA public GRANT SELECT ON TABLES TO $usuario';
END
\$\$;
EOF

# Detecta versão PostgreSQL
PG_DATA=$(ps aux | grep -oP '^postgres .*postmaster.*-D *\K.*')
PG_VERSION=$(cat $PG_DATA/PG_VERSION)
cd "$PG_DATA"

# Remove entradas antigas no pg_hba.conf
sed -i "/$usuario/d" pg_hba.conf

# Adiciona nova entrada
if [[ "$PG_VERSION" == "14" || "$PG_VERSION" < "14" ]]; then
  echo "host    all     $usuario    samenet    scram-sha-256" >> pg_hba.conf
else
  echo "host    all     $usuario    samenet    md5" >> pg_hba.conf
fi

# Recarrega PostgreSQL
echo "[INFO] Recarregando PostgreSQL..." | tee -a "$LOG_FILE"
service postgresql-$PG_VERSION reload

# Testes de conexão
echo "[INFO] Testando acesso com SELECTs..." | tee -a "$LOG_FILE"
if PGPASSWORD="$senha" psql -X -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;" > /dev/null 2> erro.log && \
   PGPASSWORD="$senha" psql -X -h "$END_SERVIDOR" -U "$usuario" -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM unidademedida LIMIT 1;" > /dev/null 2>> erro.log; then
  echo "" | tee -a "$LOG_FILE"
  echo "✅ Usuário criado e acesso validado com sucesso!" | tee -a "$LOG_FILE"
  echo "Usuário: $usuario" | tee -a "$LOG_FILE"
  echo "Senha: $senha" | tee -a "$LOG_FILE"
  echo "Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
  echo "Base: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
  echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
  echo "Porta: 5432" | tee -a "$LOG_FILE"
  echo "" | tee -a "$LOG_FILE"
  read -p "Pressione ENTER para encerrar..."


else
  echo "" | tee -a "$LOG_FILE"
  echo "❌ Falha na execução dos SELECTs com o usuário $usuario!" | tee -a "$LOG_FILE"
  cat erro.log | tee -a "$LOG_FILE"
  read -p "Deseja desfazer o processo? [s/N]: " resposta
  if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "[INFO] Revertendo criação do usuário..." | tee -a "$LOG_FILE"
    psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" -c "DROP ROLE IF EXISTS \"$usuario\";"
    sed -i "/$usuario/d" pg_hba.conf
    service postgresql-$PG_VERSION reload
    echo "Rollback concluído." | tee -a "$LOG_FILE"
  fi
fi
