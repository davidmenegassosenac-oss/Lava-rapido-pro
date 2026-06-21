-- ============================================================
-- MIGRAÇÃO 006 — RASTREABILIDADE: quem criou cada lavagem
-- Lava Rápido SaaS
--
-- Adiciona a coluna `criado_por` (referência ao usuário que
-- registrou a ordem) em ordens_servico e historico, e atualiza
-- o trigger fn_ordem_paga para propagar essa informação quando
-- a ordem é movida para o histórico ao ser paga.
--
-- Execute no SQL Editor do Supabase.
-- ============================================================

-- ── 1. Adicionar coluna em ordens_servico ──────────────────────────────
ALTER TABLE public.ordens_servico
  ADD COLUMN IF NOT EXISTS criado_por UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

-- ── 2. Adicionar a mesma coluna em historico ───────────────────────────
ALTER TABLE public.historico
  ADD COLUMN IF NOT EXISTS criado_por UUID REFERENCES public.profiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_ordens_criado_por ON public.ordens_servico(criado_por);
CREATE INDEX IF NOT EXISTS idx_historico_criado_por ON public.historico(criado_por);

-- ── 3. Atualizar o trigger fn_ordem_paga para propagar criado_por ──────
-- Substitui a função existente, adicionando a coluna no INSERT que
-- copia a ordem para o histórico quando o status muda para 'Pago'.
CREATE OR REPLACE FUNCTION public.fn_ordem_paga()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'Pago' AND OLD.status <> 'Pago' THEN

    INSERT INTO public.historico (
      empresa_id, ordem_id, plate, model, client,
      phone, type, value, status, color, observacoes, completed_at,
      criado_por
    ) VALUES (
      NEW.empresa_id, NEW.id, NEW.plate, NEW.model, NEW.client,
      NEW.phone, NEW.type, NEW.value, 'Pago', NEW.color,
      NEW.observacoes, NOW(),
      NEW.criado_por
    );

    INSERT INTO public.caixa_movimentos (
      empresa_id, tipo, categoria, descricao, valor, data
    ) VALUES (
      NEW.empresa_id, 'entrada', 'lavagem',
      NEW.type || ' — ' || NEW.model || ' (' || NEW.plate || ')',
      NEW.value, CURRENT_DATE
    );

    DELETE FROM public.ordens_servico WHERE id = NEW.id;

    RETURN NULL;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Confirmar as colunas foram criadas
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public' AND column_name = 'criado_por';
