# Changelog — Lava Rápido Pro

## [30/06/2026] — Estabilização crítica: Auth Mobile, UX Defensiva e Correções de Regressão

### 🔴 Corrigido — Crítico (Produção)

- **Login exigindo múltiplos cliques / loop de "Cadastrar Empresa":** causa raiz era dupla — (1) disparo duplo de `SIGNED_OUT`/`SIGNED_IN` pelo Supabase durante login criava condição de corrida no estado `session`; (2) dado corrompido no banco (`profiles.empresa_id = NULL`) para a conta do owner Zanata, desde 12/06. Corrigido com estado único `initializing`, ref `isLoggingIn` para filtrar eventos temporários, e `UPDATE` SQL direto vinculando o profile à empresa correta.
- **Tela preta/travada ao voltar de background no mobile:** o Supabase reemite `SIGNED_IN` (não apenas `TOKEN_REFRESHED`) ao revalidar sessão após o navegador congelar a aba. O handler tratava isso como login novo, destruindo `profile`/`empresa`/`assInfo`. Corrigido com `profileRef` que distingue revalidação (mesmo usuário) de login genuíno.
- **Crash de runtime ao abrir aba "Nova Lavagem":** funções `maskPlate`/`maskPhone` referenciadas em `onChange` mas nunca declaradas no escopo do componente. Corrigido declarando-as dentro do `NewWashScreen`.
- **Crash de runtime ao abrir aba "Folha":** `useEffect` residual de uma correção anterior chamava `carregar()` (função exclusiva do `CRMScreen`) dentro do `FolhaScreen`, que usa `fetchTudo()`. Removido.
- **Folha de pagamento zerada:** três tabelas (`funcionario_diaria`, `folha_pagamentos`, `folha_dias_trabalhados`) tinham `select()` com coluna `funcionario_id`, mas o schema real usa `profile_id`. Corrigido em todas as três queries.
- **Aba Serviços exibindo lista vazia:** `.order('created_at')` referenciava uma coluna que não existe (o campo real tem outro nome). Query rejeitada silenciosamente pelo Postgres. Removido o `.order()`, ordenação movida para o cliente.
- **Aba Equipe sem listar funcionários:** `select()` misturava colunas de `profiles` com colunas de `funcionario_diaria` (`tipo_pagamento`, `valor_diaria`), que não existem na tabela `profiles`. Corrigido para `select('*')`.
- **Horários da empresa não persistindo:** função de salvamento não tratava o retorno de `error` do Supabase — falhas de RLS ou rede eram silenciosas, dando falso feedback de sucesso. Adicionado `try/catch`/`alert()` explícito.
- **Card "Cliente Recuperado" não aparecendo / regressão do CRM:** a lógica original considerava apenas o registro mais recente por telefone. Um retorno posterior sem a flag do banco sobrescrevia a detecção do retorno anterior, fazendo clientes já recuperados voltarem à lista de sumidos. Corrigido com dois `Set` permanentes (placa + telefone) construídos a partir de todo o histórico disponível — imunidade vitalícia após a primeira recuperação confirmada.
- **Card "Receita de Hoje" com valores de ontem:** cálculo de datas usava `.toISOString()` (UTC) em vez do fuso local, vazando lavagens da noite anterior para o dia seguinte. Corrigido com `setHours(0,0,0,0)` no fuso local em todos os pontos (KPIs e gráfico).
- **Gráfico de Relatórios dessincronizado dos cards:** gráfico usava `caixa_movimentos` como fonte, cards usavam `historico` — números diferentes para o mesmo período. Unificado para usar `historico` em ambos.
- **Registro "Pago" desaparecendo da fila sem entrar no Histórico:** a transição dependia de um trigger de banco não confirmável. Substituído por lógica explícita no frontend: `UPDATE` do status → `INSERT` em `historico` → só então `DELETE` da fila, com `try/catch` e alerta visível em caso de falha em qualquer etapa.

### 🟡 Corrigido — Performance (sem regressão de UX)

- **G1 — Lazy-Mount de abas:** telas passaram de desmontar/remontar a cada troca para permanecerem montadas com `display:none`/`flex`, preservando estado e canais Realtime. Elimina ~160 queries redundantes por dia de operação.
- **G2 — Double-fetch no INSERT do Realtime da Fila:** removido `fetchQueue()` redundante após atualização otimista do estado local.
- **G3 — Histórico com janela de 6 meses** para badge do CRM e cálculo de sumidos (antes: sem filtro de data, processando o histórico completo).
- **G4 — Canal Realtime unificado na Folha:** de 3 WebSockets separados para 1 canal com 3 listeners.
- **G5 — KPIs financeiros em `useMemo`** com defesas de null-safety contra dados históricos incompletos.

### 🟢 Adicionado — Trilha 3: UX/UI Defensiva

- **Máscara de placa:** formatação automática em tempo real (uppercase, hífen no padrão antigo `ABC-1234`, sem hífen no Mercosul `ABC1D23`), com validação por regex que impede o envio de placas fora do padrão — sem bloquear a digitação.
- **Máscara de telefone:** formatação progressiva `(49) 99999-9999` conforme o usuário digita.
- **Empty states premium:** telas de Fila, CRM e Histórico exibem mensagens centralizadas com ícone e texto orientativo (ex: "Fila vazia — adicione um veículo na aba Nova Lavagem") em vez de tela em branco.
- **Banners de erro amigáveis:** falhas de rede em operações críticas (avançar status, salvar histórico) exibem banner vermelho no topo da tela com mensagem clara, em vez de falhar silenciosamente.
- **`ErrorBoundary` global:** qualquer erro de runtime não capturado nas camadas anteriores agora mostra uma tela de erro com botão "Recarregar", eliminando o cenário de tela preta silenciosa.

### 📄 Documentação

- Criado `docs/arquitetura.md` com as regras anti-regressão do motor de autenticação, isolamento de escopo do lazy-mount, e mapeamento de nomes de coluna reais do banco.
