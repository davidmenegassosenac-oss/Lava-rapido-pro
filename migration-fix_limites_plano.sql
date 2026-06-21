-- ============================================================
-- CORREÇÃO DE SEGURANÇA: Limites de plano nunca verificados
-- ============================================================
-- Problema identificado na auditoria: a tabela planos_config
-- já existia com max_usuarios e max_ordens_mes, mas nenhuma
-- parte do sistema (frontend ou banco) verificava esses limites
-- antes de criar novos registros. Isso permitia que qualquer
-- empresa, independente do plano, cadastrasse usuários e ordens
-- ilimitadamente — anulando a segmentação comercial dos planos.
--
-- Esta migration cria:
--   1. fn_verificar_limite_ordens — chamada antes de inserir uma
--      nova ordem de serviço, bloqueia se o limite mensal do
--      plano foi atingido.
--   2. Um trigger BEFORE INSERT em ordens_servico que chama essa
--      função automaticamente — protege mesmo que alguém tente
--      inserir direto via API REST, ignorando o frontend.
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

CREATE OR REPLACE FUNCTION public.fn_verificar_limite_ordens()
RETURNS TRIGGER AS $$
DECLARE
  v_plano        TEXT;
  v_max_ordens   INTEGER;
  v_total_mes    INTEGER;
  v_inicio_mes   DATE;
BEGIN
  v_inicio_mes := date_trunc('month', CURRENT_DATE)::DATE;

  -- Buscar plano ativo da empresa
  SELECT a.plano INTO v_plano
  FROM public.assinaturas a
  WHERE a.empresa_id = NEW.empresa_id
  LIMIT 1;

  IF v_plano IS NULL THEN
    v_plano := 'trial';
  END IF;

  -- Buscar limite do plano
  SELECT max_ordens_mes INTO v_max_ordens
  FROM public.planos_config
  WHERE plano = v_plano;

  IF v_max_ordens IS NULL THEN
    v_max_ordens := 50; -- fallback conservador caso o plano não esteja configurado
  END IF;

  -- Contar ordens criadas neste mês (fila ativa + já movidas para histórico)
  SELECT
    (SELECT COUNT(*) FROM public.ordens_servico
       WHERE empresa_id = NEW.empresa_id AND created_at >= v_inicio_mes)
    +
    (SELECT COUNT(*) FROM public.historico
       WHERE empresa_id = NEW.empresa_id AND created_at >= v_inicio_mes)
  INTO v_total_mes;

  IF v_total_mes >= v_max_ordens THEN
    RAISE EXCEPTION 'LIMITE_PLANO_EXCEDIDO: Limite de % ordens/mês do plano atingido. Faça upgrade para continuar.', v_max_ordens
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_verificar_limite_ordens ON public.ordens_servico;
CREATE TRIGGER trg_verificar_limite_ordens
  BEFORE INSERT ON public.ordens_servico
  FOR EACH ROW EXECUTE FUNCTION public.fn_verificar_limite_ordens();

-- ============================================================
-- RPC: fn_verificar_limite_usuarios
-- Usada pela Edge Function create-employee, e também exposta
-- para o frontend poder mostrar o limite ANTES de tentar criar
-- (melhor UX: avisa antes de preencher o formulário todo).
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_status_limites_plano(p_empresa_id UUID)
RETURNS JSONB AS $$
DECLARE
  v_plano       TEXT;
  v_max_users   INTEGER;
  v_max_ordens  INTEGER;
  v_cur_users   INTEGER;
  v_cur_ordens  INTEGER;
  v_inicio_mes  DATE;
BEGIN
  v_inicio_mes := date_trunc('month', CURRENT_DATE)::DATE;

  SELECT a.plano INTO v_plano
  FROM public.assinaturas a WHERE a.empresa_id = p_empresa_id LIMIT 1;
  IF v_plano IS NULL THEN v_plano := 'trial'; END IF;

  SELECT max_usuarios, max_ordens_mes INTO v_max_users, v_max_ordens
  FROM public.planos_config WHERE plano = v_plano;

  SELECT COUNT(*) INTO v_cur_users
  FROM public.profiles WHERE empresa_id = p_empresa_id AND ativo = TRUE;

  SELECT
    (SELECT COUNT(*) FROM public.ordens_servico WHERE empresa_id = p_empresa_id AND created_at >= v_inicio_mes)
    +
    (SELECT COUNT(*) FROM public.historico WHERE empresa_id = p_empresa_id AND created_at >= v_inicio_mes)
  INTO v_cur_ordens;

  RETURN jsonb_build_object(
    'plano', v_plano,
    'usuarios_atual', v_cur_users,
    'usuarios_limite', COALESCE(v_max_users, 2),
    'usuarios_disponivel', COALESCE(v_max_users, 2) - v_cur_users,
    'ordens_mes_atual', v_cur_ordens,
    'ordens_mes_limite', COALESCE(v_max_ordens, 50),
    'ordens_mes_disponivel', COALESCE(v_max_ordens, 50) - v_cur_ordens
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Confirmar criação
SELECT routine_name FROM information_schema.routines
WHERE routine_schema='public' AND routine_name IN
  ('fn_verificar_limite_ordens','fn_status_limites_plano');
