-- ============================================================
-- LIMPEZA: remover versão antiga (stub) de fn_processar_webhook
-- ============================================================
-- O PostgreSQL permite duas funções com o mesmo nome se os
-- parâmetros forem diferentes (overload). A migration 005 criou
-- uma nova versão de fn_processar_webhook com 4 parâmetros,
-- mas a versão antiga (3 parâmetros, da migration 004) continua
-- existindo no banco — ela nunca mais é chamada por nada no
-- sistema, mas é boa prática remover para não gerar confusão.
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

DROP FUNCTION IF EXISTS public.fn_processar_webhook(TEXT, TEXT, JSONB);

-- Confirmar que sobrou só a versão nova (4 parâmetros)
SELECT
  p.proname AS routine_name,
  pg_get_function_arguments(p.oid) AS argumentos
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'fn_processar_webhook';
