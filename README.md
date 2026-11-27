# PixGuard – protótipo de dados (A3 Análise de Dados e Big Data)

Startup fictícia que alerta o cliente antes de um Pix para uma chave com histórico de golpe.
Banco: **MySQL 8.4 (InnoDB)**. Todos os dados são **fictícios**, gerados de forma determinística.

## Arquivos

| Arquivo | Conteúdo |
| --- | --- |
| `01_schema.sql` | Cria o banco `pixguard`: 9 tabelas, chaves, CHECKs e índices |
| `02_dados.sql` | Carga fictícia: 60 usuários, ~3.200 Pix, denúncias e alertas |
| `03_governanca.sql` | Views sem dados sensíveis e papéis de acesso (LGPD) |
| `04_consultas.sql` | 8 consultas que respondem às perguntas de negócio |
| `05_qualidade.sql` | Auditorias de qualidade + testes que devem ser rejeitados |
| `executar.ps1` | Roda tudo e salva `resultados.txt` e `resultados_testes.txt` |

## Como rodar

```powershell
powershell -ExecutionPolicy Bypass -File C:\Projetos\pixguard\executar.ps1
```

O script pede usuário e senha do MySQL, cria um arquivo de credenciais temporário
(apagado ao final) e executa os scripts na ordem. Também dá para abrir os `.sql`
no MySQL Workbench e executar um por um, na ordem numérica.

## App visual (para o pitch)

Pasta `app/`. Não precisa instalar nada: usa o PowerShell do Windows e o `mysql.exe`.

1. Dê dois cliques em `app\INICIAR_PIXGUARD.bat`.
2. Digite o usuário e a senha do MySQL. O navegador abre em `http://localhost:8080`.
3. Deixe a janela preta aberta durante a apresentação (Ctrl+C para parar).

| Aba | O que mostra |
| --- | --- |
| Fazer Pix | Escolhe pagador, chave e valor; o PixGuard calcula o risco (regras R01–R05) antes do envio. Enviar ou desistir grava o Pix e os alertas no MySQL |
| Denúncias | Registra denúncia de um Pix e permite ao suporte confirmar ou marcar como improcedente |
| Painel | KPIs, gráfico semanal de golpes (concretizados x evitados), chaves mais denunciadas e últimos Pix |

Botões de exemplo prontos: **Pix normal** (risco 0), **Pix para golpista** (risco 100),
**Valor inválido** e **Pix para si mesmo** (o próprio MySQL recusa e o erro aparece na tela).

Depois da apresentação, rode `app\limpar_demo.sql` no Workbench para apagar os Pix
de demonstração e voltar aos números do relatório.
