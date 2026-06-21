-- ============================================================
-- CORREÇÃO: Habilitar Realtime para a tabela ordens_servico
-- ============================================================
-- Diagnóstico: a publicação "supabase_realtime" existia mas estava
-- vazia — nenhuma tabela publicava mudanças via Realtime. Por isso
-- o app nunca recebia eventos de INSERT/UPDATE/DELETE entre
-- diferentes celulares conectados simultaneamente, e só "atualizava"
-- quando o usuário forçava um refetch manual (ex: ao bater no erro
-- de lock otimista, que recarrega a fila).
--
-- Isso adiciona ordens_servico à publicação, fazendo o Postgres
-- de fato emitir os eventos que o app já está escutando.
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE public.ordens_servico;

-- Confirmar que foi adicionada com sucesso
SELECT schemaname, tablename
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime';
