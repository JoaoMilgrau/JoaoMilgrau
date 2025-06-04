#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="usuario_chinchila_webdecisor.log"
echo "########################################################" | tee -a "$LOG_FILE"
echo "  Criação e Configuração do Usuário: chinchila_webdecisor  " | tee -a "$LOG_FILE"
echo "########################################################" | tee -a "$LOG_FILE"

read -s -p "Senha do usuário postgres: " PGPASSWORD
echo
export PGPASSWORD

read -s -p "Digite a senha para o usuário chinchila_webdecisor: " senha
echo

source /etc/wildfly.conf

if [[ -z "${END_SERVIDOR:-}" || -z "${CHINCHILA_DS_DATABASENAME:-}" ]]; then
  echo "Erro: END_SERVIDOR ou CHINCHILA_DS_DATABASENAME não definidos." | tee -a "$LOG_FILE"
  exit 1
fi

echo "[INFO] Criando usuário no banco de dados..." | tee -a "$LOG_FILE"

psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" <<EOF
DO \$\$
DECLARE
  usuario varchar := 'chinchila_webdecisor';
  senha varchar := '$senha';
BEGIN
  EXECUTE format('DROP ROLE IF EXISTS %I', usuario);
  EXECUTE format('CREATE ROLE %I LOGIN PASSWORD ''%s'' NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE CONNECTION LIMIT 5', usuario, senha);

  EXECUTE 'GRANT USAGE ON SCHEMA integracao_webdecisor TO chinchila_webdecisor';

  FOREACH obj IN ARRAY ARRAY[
    'v_extracaocliente', 'v_extracaoproduto', 'v_extracaoidentificador',
    'v_extracaogrupo', 'v_extracaotipo', 'v_extracaofabricante',
    'v_extracaovendedor', 'v_extracaofornecedor', 'v_extracaoinformacoesvenda',
    'v_extracaovenda', 'v_extracaocompra', 'v_extracaonotasfiscais',
    'v_extracaoestoque'
  ]
  LOOP
    EXECUTE format('GRANT SELECT ON integracao_webdecisor.%I TO chinchila_webdecisor', obj);
  END LOOP;

  EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA public TO chinchila_webdecisor';
  EXECUTE 'ALTER DEFAULT PRIVILEGES FOR USER chinchila IN SCHEMA public GRANT SELECT ON TABLES TO chinchila_webdecisor';
END
\$\$;
EOF

PG_DATA=$(ps aux | grep -oP '^postgres .*postmaster.*-D *\K.*')
PG_VERSION=$(cat $PG_DATA/PG_VERSION)
cd "$PG_DATA"

sed -i "/chinchila_webdecisor/d" pg_hba.conf

if [[ "$PG_VERSION" == "14" || "$PG_VERSION" < "14" ]]; then
  echo "host    all     chinchila_webdecisor    samenet    scram-sha-256" >> pg_hba.conf
else
  echo "host    all     chinchila_webdecisor    samenet    md5" >> pg_hba.conf
fi

echo "[INFO] Recarregando PostgreSQL..." | tee -a "$LOG_FILE"
service postgresql-$PG_VERSION reload

echo "[INFO] Testando acesso com SELECTs..." | tee -a "$LOG_FILE"
{
  PGPASSWORD="$senha" psql -X -h "$END_SERVIDOR" -U chinchila_webdecisor -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM integracao_webdecisor.v_extracaocliente LIMIT 1;"
  PGPASSWORD="$senha" psql -X -h "$END_SERVIDOR" -U chinchila_webdecisor -d "$CHINCHILA_DS_DATABASENAME" -c "SELECT * FROM unidademedida LIMIT 1;"
} > /dev/null 2> erro.log && {
  echo "" | tee -a "$LOG_FILE"
  echo "✅ Usuário chinchila_webdecisor criado e testado com sucesso!" | tee -a "$LOG_FILE"
  echo "Senha: [oculta]" | tee -a "$LOG_FILE"
  echo "Servidor: $END_SERVIDOR" | tee -a "$LOG_FILE"
  echo "Base: $CHINCHILA_DS_DATABASENAME" | tee -a "$LOG_FILE"
  echo "Versão PostgreSQL: $PG_VERSION" | tee -a "$LOG_FILE"
  echo ""
  read -p "Pressione ENTER para encerrar..."
} || {
  echo "" | tee -a "$LOG_FILE"
  echo "❌ Falha na execução do SELECT com o usuário chinchila_webdecisor!" | tee -a "$LOG_FILE"
  cat erro.log | tee -a "$LOG_FILE"
  echo ""
  read -p "Deseja desfazer o processo? [s/N]: " resposta

  if [[ "$resposta" =~ ^[sS]$ ]]; then
    echo "[INFO] Revertendo criação do usuário..." | tee -a "$LOG_FILE"
    psql -X -h "$END_SERVIDOR" -U postgres -d "$CHINCHILA_DS_DATABASENAME" -c "DROP ROLE IF EXISTS chinchila_webdecisor;"
    sed -i "/chinchila_webdecisor/d" pg_hba.conf
    service postgresql-$PG_VERSION reload
    echo "Rollback concluído." | tee -a "$LOG_FILE"
  else
    echo ""
    echo "⚠️  ATENÇÃO, PROCESSO FINALIZADO COM FALHAS" | tee -a "$LOG_FILE"
    echo "Erro encontrado:" | tee -a "$LOG_FILE"
    cat erro.log | tee -a "$LOG_FILE"
  fi
}
