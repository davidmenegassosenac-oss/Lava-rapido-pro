-- ============================================================
-- DIAGNÓSTICO + CORREÇÃO: eventos DELETE incompletos no Realtime
-- ============================================================
-- Quando uma ordem é marcada como "Pago", o trigger fn_ordem_paga
-- cancela o UPDATE original e executa um DELETE puro na linha.
-- O Postgres deveria emitir um evento DELETE via Realtime para que
-- o app remova o carro da fila em todos os celulares conectados.
--
-- Por padrão, o Postgres só inclui a chave primária (id) no payload
-- de eventos DELETE — a menos que REPLICA IDENTITY esteja configurado
-- como FULL, que inclui a linha inteira como ela era antes do delete.
-- Isso pode causar o atraso/falha observado: o evento chega, mas com
-- dados incompletos para o filtro de empresa_id funcionar corretamente
-- do lado do Realtime.
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

-- 1. Verificar a configuração atual
SELECT relname, CASE relreplident
  WHEN 'd' THEN 'default (só chave primária)'
  WHEN 'f' THEN 'full (linha completa)'
  WHEN 'n' THEN 'nothing'
  WHEN 'i' THEN 'index'
END AS replica_identity
FROM pg_class
WHERE relname = 'ordens_servico';

-- 2. Corrigir: garantir que eventos DELETE incluam a linha completa,
--    o que é necessário para o filtro `empresa_id=eq.X` do Realtime
--    funcionar corretamente em eventos de exclusão.
ALTER TABLE public.ordens_servico REPLICA IDENTITY FULL;

-- 3. Confirmar a mudança
SELECT relname, CASE relreplident
  WHEN 'd' THEN 'default (só chave primária)'
  WHEN 'f' THEN 'full (linha completa)'
  WHEN 'n' THEN 'nothing'
  WHEN 'i' THEN 'index'
END AS replica_identity
FROM pg_class
WHERE relname = 'ordens_servico';
