# Expediente para iPhone

Agenda profissional para quem trabalha com hora marcada: cabeleireiros, manicures, esteticistas, personal trainers, professores particulares, terapeutas, advogados, contadores, técnicos e prestadores de serviço em geral. Feito pela Color Software a partir do Sessão (o app para psicólogos), sem as funções exclusivas da saúde.

**Versão 0.1:** só iPhone (e iPad), sem servidor e sem sincronização. Tudo fica no aparelho, cifrado (AES-256). Os dados só saem do iPhone quando você usa uma função que precisa disso: exportar um PDF ou um backup, abrir o WhatsApp, buscar o endereço pelo CEP (só o CEP vai ao ViaCEP; dá para desligar) ou emitir NFS-e pelo Sistema Nacional.

## O que faz

**Do Sessão, mantido:**

- **Agenda** em tela cheia por dia, semana e mês; atendimentos recorrentes (toda semana, a cada 2 semanas, todo mês), remarcar, desmarcar (com aviso ou apagando), retorno com qualquer intervalo e regra de dias úteis, dias de atendimento, feriados nacionais e próprios, intervalos (almoço). A agenda de hoje acompanha o relógio.
- **Tags** como tipos de serviço: cor, duração, valor e mensagem de WhatsApp próprios.
- **Clientes**: cadastro com telefone (+55), CPF, endereço pelo CEP, responsável, valor próprio, documento anexado (contrato, ficha), importar dos Contatos e salvar nos Contatos. Nome clicável em todas as telas.
- **WhatsApp** sem API nem servidor: o botão abre a conversa com a mensagem pronta.
- **Anotações** por atendimento, com editor de texto completo, e PDF com ou sem senha.
- **Financeiro**: recebido, em aberto, inadimplência, previsto e formas de pagamento; valor por tag ou por cliente; retorno sem custo.
- **Relatórios** em PDF, **NFS-e Nacional** pelo app (Santo André/SP, certificado A1) ou controle de notas emitidas fora, **segurança** (senha, Face ID, chave de recuperação, registro de acessos com cadeia SHA-256) e **backup cifrado** em arquivo.

**Ficou de fora:** prontuário, medicações, condições pré-existentes, psiquiatria (atestados, escalas, receitas), CRP/CRM e o backup/sincronização pela nuvem (Supabase).

**Novidades do Expediente:**

- **Área de atuação e nome de quem é atendido:** no cadastro você escolhe a área (beleza, saúde e terapias, esporte, aulas, consultoria/advocacia, serviços técnicos ou outra) e se chama quem atende de cliente, paciente ou aluno. O app usa esse nome em todas as telas e já cria as tags da área.
- **Cobrança pelo WhatsApp com Pix:** botão **Cobrar** nos atendimentos realizados e não pagos (também para vários de uma vez, na ficha do cliente). Com a chave Pix em Ajustes, a mensagem leva o **Pix copia e cola com o valor**, gerado no próprio iPhone (padrão BR Code do Banco Central).
- **Confirmação de véspera:** o botão verde do WhatsApp aparece de hoje em diante, e a mensagem diz "hoje", "amanhã" ou o dia ({data}).
- **Local do atendimento:** endereço (abre no Mapas), "Online" ou link da reunião (Meet, Zoom, Teams), com local padrão em Ajustes e campo {local} nas mensagens.
- **Pacotes pré-pagos:** ex.: 10 aulas ou 4 escovas. O pagamento é do pacote; cada atendimento ligado a ele desconta do saldo (faltas contam, cancelamentos com aviso não). Validade opcional, cobrança e recibo do pacote.
- **Despesas** por categoria e **resultado do mês** (recebido menos despesas) no Financeiro e no relatório.
- **Recibo em PDF** de cada pagamento ou pacote, com valor por extenso, e **cabeçalho e rodapé** (timbre) em todos os PDFs.
- **Aviso antes de cada atendimento** (10 min a 1 dia antes), no próprio iPhone.

## Como instalar no iPhone (pelo Windows, sem Mac)

O app é compilado automaticamente no GitHub a cada mudança na `main`. O arquivo fica na página **Releases** deste repositório ("Expediente para iPhone (última versão)"), com o nome `Expediente.ipa`.

1. No PC, instale o **iTunes baixado do site da Apple** (a versão da Microsoft Store não funciona com o Sideloadly).
2. Instale o **Sideloadly** (sideloadly.io).
3. Ligue o iPhone no PC pelo cabo e toque em **Confiar** no iPhone.
4. Abra o Sideloadly, arraste o `Expediente.ipa`, informe seu **Apple ID** e clique em **Start**.
5. No iPhone, se preciso: **Ajustes › Privacidade e Segurança › Modo de Desenvolvedor**, e **Ajustes › Geral › VPN e Gerenciamento de Dispositivos** › seu Apple ID › **Confiar**.

**Validade:** com Apple ID gratuito, o app para de abrir depois de 7 dias. Para renovar, repita o passo 4 com o mesmo `.ipa`, **sem apagar o app antes**. Faça backups pelo app (Ajustes › Backup): sem servidor, o backup é a única cópia fora do iPhone.

O Expediente tem identificador próprio (`br.com.colorsoftware.expediente`), então pode ficar instalado ao lado do Sessão.

## Estrutura do código

```
Expediente/Core    dados, cofre cifrado, registro de acessos, agenda, financeiro, pacotes, Pix, PDF, NFS-e, backup
Expediente/UI      telas em SwiftUI; editor de texto em UIKit
Expediente/App     estado do app, bloqueio, dados de demonstração para as capturas de tela
ExpedienteTests    testes automáticos (rodam no simulador a cada mudança)
project.yml        projeto do Xcode (gerado com XcodeGen)
.github            compilação, testes, capturas de tela e geração do .ipa
```

Requer iOS 17 ou mais novo.
