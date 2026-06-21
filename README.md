# Lava Rápido Pro

PWA (Progressive Web App) para gestão de lava-jatos — fila de lavagem em tempo real, histórico financeiro, CRM de clientes, relatórios, e controle multi-empresa (SaaS).

## Stack

- **Frontend:** React 18 (via CDN, sem build step) + Babel Standalone, em um único arquivo `index.html`
- **Backend:** Supabase (PostgreSQL, Auth, Realtime, Edge Functions)
- **Deploy:** Netlify (Netlify Drop ou conectado a este repositório)
- **Pagamentos:** Mercado Pago (webhook), com fallback de confirmação manual via Pix

## Estrutura do projeto

Devido a uma limitação do upload via navegador mobile do GitHub (que não preserva subpastas ao arrastar arquivos), os arquivos foram nomeados com prefixos descritivos em vez de pastas reais:

```
.
├── index.html                                      # App completo (frontend)
├── migration-001_multitenancy.sql                  # Tabelas base, multi-tenant
├── migration-002_rls_policies.sql                  # Row Level Security + triggers
├── migration-003_assinaturas.sql                   # Planos e assinaturas
├── migration-004_webhooks_prep.sql                 # Preparação para pagamentos
├── migration-005_pagamentos_mercadopago.sql
├── migration-006_rastreabilidade_criado_por.sql
├── migration-fix_limites_plano.sql                 # Limites de uso por plano
├── migration-fix_realtime_publication.sql          # Habilita Realtime
├── migration-fix_realtime_delete_payload.sql
├── migration-limpeza_fn_processar_webhook.sql
├── edge-function-create-employee.ts                # Cadastro seguro de funcionários
└── edge-function-mercadopago-webhook.ts            # Recebe notificações de pagamento
```

As migrations devem ser executadas em ordem (pela numeração no nome). Os dois arquivos `edge-function-*.ts` correspondem cada um a uma Edge Function diferente no Supabase — ao fazer o deploy, copie o conteúdo do arquivo certo para a função correspondente.

## Como subir uma alteração no Supabase

As migrations em `supabase/migrations/` devem ser executadas em ordem (pela numeração) no **SQL Editor** do painel do Supabase, manualmente. Este repositório não está conectado via Supabase CLI — é um histórico organizado dos scripts já aplicados.

## Como fazer deploy do frontend

Suba o arquivo `index.html` diretamente no [Netlify Drop](https://app.netlify.com/drop), ou conecte este repositório a um site do Netlify para deploy automático a cada commit.

## Como fazer deploy das Edge Functions

No painel do Supabase, em **Edge Functions → Deploy a new function → Via Editor**, cole o conteúdo do arquivo `index.ts` correspondente.

**Atenção:** o nome de exibição da função no painel do Supabase pode não corresponder à URL real gerada — sempre confirme a URL completa na aba **Overview** depois do deploy, e use exatamente essa URL nas chamadas do frontend.

## Variáveis de ambiente (Secrets) necessárias

Configradas em **Project Settings → Edge Functions → Secrets** no Supabase:

- `MERCADOPAGO_ACCESS_TOKEN`
- `MERCADOPAGO_WEBHOOK_SECRET`

(`SUPABASE_URL` e `SUPABASE_SERVICE_ROLE_KEY` já são fornecidas automaticamente pelo Supabase.)
