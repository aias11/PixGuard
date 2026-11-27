# =====================================================================
# PixGuard - servidor web local (sem instalar nada: PowerShell + mysql.exe)
# Uso:  powershell -ExecutionPolicy Bypass -File C:\Projetos\pixguard\app\servidor.ps1
# Depois abra http://localhost:8080 no navegador. Para parar: Ctrl+C.
# =====================================================================
param([int]$Porta = 8080)

$ErrorActionPreference = 'Stop'
$pasta = Split-Path -Parent $MyInvocation.MyCommand.Path
$mysql = 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe'
$inv   = [Globalization.CultureInfo]::InvariantCulture
$utf8  = New-Object Text.UTF8Encoding($false)

# --- credenciais: pedidas na hora (ou variaveis de ambiente), nunca salvas ---
$usuario = $env:PIXGUARD_USUARIO
if (-not $usuario) {
    $usuario = Read-Host 'Usuario do MySQL (Enter = root)'
    if ([string]::IsNullOrWhiteSpace($usuario)) { $usuario = 'root' }
}
$senha = $env:PIXGUARD_SENHA
if (-not $senha) {
    $seg = Read-Host 'Senha do MySQL' -AsSecureString
    $senha = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seg))
}
$tmp = Join-Path $env:TEMP ("pixguard_app_" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$cnf = Join-Path $tmp 'cliente.cnf'
[IO.File]::WriteAllText($cnf, "[client]`nuser=$usuario`npassword=`"$senha`"`ndefault-character-set=utf8mb4`ndatabase=pixguard`n", $utf8)
$senha = $null

# Mensagens amigaveis para as regras do banco (o erro original tambem e mostrado)
$amigavel = @{
    'ck_tx_valor'   = 'O valor do Pix precisa ser maior que zero.'
    'ck_tx_contas'  = 'Nao e possivel fazer Pix para a propria conta.'
    'fk_tx_origem'  = 'A conta de origem nao existe.'
    'fk_tx_chave'   = 'A chave Pix de destino nao existe.'
    'uq_den_tx'     = 'Este Pix ja foi denunciado.'
    'ck_den_link'   = 'Golpe de link falso exige informar o dominio do site.'
}

# ---------------------------------------------------------------------
# Executa SQL no MySQL e devolve as linhas do ULTIMO SELECT como objetos
# ---------------------------------------------------------------------
function Invoke-Sql([string]$sql) {
    $arq = Join-Path $tmp ("q_" + [guid]::NewGuid() + '.sql')
    [IO.File]::WriteAllText($arq, $sql, $utf8)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $mysql
    $psi.Arguments = "--defaults-extra-file=`"$cnf`" --batch -e `"source $($arq -replace '\\','/')`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $err = $errTask.Result
    Remove-Item $arq -Force -ErrorAction SilentlyContinue

    if ($p.ExitCode -ne 0) {
        $msg = ($err -split "`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 1)
        if (-not $msg) { $msg = $err }
        $codigo = ''; $texto = $msg
        if ($msg -match 'ERROR (\d+) \(\w+\)[^:]*?(?: in file: ''[^'']*'')?: (.*)') {
            $codigo = $Matches[1]; $texto = $Matches[2].Trim()
        }
        $amig = $null
        foreach ($k in $amigavel.Keys) { if ($texto -match $k) { $amig = $amigavel[$k] } }
        throw (New-Object Exception ("SQL|$codigo|$amig|$texto"))
    }

    $linhas = @($out -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($linhas.Count -eq 0) { return }
    $cab = $linhas[0] -split "`t"
    $res = New-Object Collections.ArrayList
    for ($i = 1; $i -lt $linhas.Count; $i++) {
        $vals = $linhas[$i] -split "`t"
        $o = [ordered]@{}
        for ($j = 0; $j -lt $cab.Count; $j++) {
            $v = $vals[$j]
            if ($v -eq 'NULL') { $v = $null }
            elseif ($v) { $v = $v -replace '\\n', "`n" -replace '\\t', "`t" -replace '\\\\', '\' }
            $o[$cab[$j]] = $v
        }
        [void]$res.Add([pscustomobject]$o)
    }
    return $res.ToArray()   # quem chama usa @( ) para garantir uma lista
}

# --- validacao dos parametros (so numeros e listas fechadas chegam ao SQL) ---
function Get-Inteiro($v, $nome) {
    $n = 0
    if (-not [int]::TryParse([string]$v, [ref]$n)) { throw (New-Object Exception "VAL|Campo '$nome' invalido.") }
    return $n
}
function Get-Valor($v) {
    $d = [decimal]0
    $s = ([string]$v).Replace(',', '.')
    if (-not [decimal]::TryParse($s, [Globalization.NumberStyles]::Number -bor [Globalization.NumberStyles]::AllowLeadingSign, $inv, [ref]$d)) {
        throw (New-Object Exception "VAL|Valor invalido.")
    }
    return [decimal]::Round($d, 2)
}

# ---------------------------------------------------------------------
# Motor de risco: aplica as regras R01-R05 a um Pix antes de enviar
# ---------------------------------------------------------------------
function Get-Risco($origem, $chave, $valor) {
    $disp = if ($origem -le 50) { $origem } else { 51 }
    $sql = @"
SELECT c.id AS chave_id, c.valor_mascarado AS chave, c.tipo AS tipo_chave,
       ct.id AS conta_destino, u.apelido AS titular, i.nome AS banco,
       DATE_FORMAT(ct.data_abertura, '%d/%m/%Y') AS conta_aberta_em,
       DATEDIFF(NOW(), ct.data_abertura) AS idade_conta_dias,
       (SELECT COUNT(*) FROM denuncia d WHERE d.chave_denunciada_id = c.id AND d.status = 'CONFIRMADA') AS den_confirmadas,
       (SELECT COUNT(*) FROM denuncia d WHERE d.chave_denunciada_id = c.id AND d.status = 'EM_ANALISE') AS den_em_analise,
       (SELECT COUNT(DISTINCT t.conta_origem_id) FROM transacao t
         WHERE t.conta_destino_id = ct.id AND t.status = 'CONCLUIDA' AND t.data_hora >= NOW() - INTERVAL 14 DAY) AS pagadores_14d,
       (SELECT ROUND(COALESCE(AVG(t.valor), 0), 2) FROM transacao t
         WHERE t.conta_origem_id = $origem AND t.status = 'CONCLUIDA') AS media_pagador,
       (SELECT COUNT(DISTINCT t.conta_origem_id) FROM transacao t WHERE t.dispositivo_id = $disp) AS contas_no_aparelho,
       HOUR(NOW()) AS hora_atual,
       (SELECT apelido FROM usuario WHERE id = (SELECT usuario_id FROM conta WHERE id = $origem)) AS pagador
FROM chave_pix c
JOIN conta ct      ON ct.id = c.conta_id
JOIN usuario u     ON u.id = ct.usuario_id
JOIN instituicao i ON i.id = ct.instituicao_id
WHERE c.id = $chave;
"@
    $r = @(Invoke-Sql $sql)
    if ($r.Count -eq 0) { throw (New-Object Exception "VAL|Chave Pix nao encontrada.") }
    $e = $r[0]
    $regras = @(Invoke-Sql "SELECT codigo, descricao, peso FROM regra_risco ORDER BY codigo;")
    $peso = @{}; $desc = @{}
    foreach ($x in $regras) { $peso[$x.codigo] = [int]$x.peso; $desc[$x.codigo] = $x.descricao }

    $disparadas = New-Object Collections.ArrayList
    $den   = [int]$e.den_confirmadas
    $idade = [int]$e.idade_conta_dias
    $media = [decimal]::Parse($e.media_pagador, $inv)
    $hora  = [int]$e.hora_atual
    if ($den -gt 0) {
        $pts = [Math]::Min($peso['R01'] * $den, 80)
        [void]$disparadas.Add([ordered]@{ codigo='R01'; descricao=$desc['R01']; pontos=$pts
            detalhe="$den denuncia(s) confirmada(s) contra esta chave ($($peso['R01']) pontos cada, maximo 80)" })
    }
    if ($idade -lt 30) {
        [void]$disparadas.Add([ordered]@{ codigo='R02'; descricao=$desc['R02']; pontos=$peso['R02']
            detalhe="Conta aberta ha $idade dia(s)" })
    }
    if ($media -gt 0 -and $valor -gt 3 * $media) {
        [void]$disparadas.Add([ordered]@{ codigo='R03'; descricao=$desc['R03']; pontos=$peso['R03']
            detalhe=("Media do pagador: R$ {0:N2}; este Pix e {1:N1}x a media" -f $media, ($valor / $media)) })
    }
    if ([int]$e.contas_no_aparelho -ge 3) {
        [void]$disparadas.Add([ordered]@{ codigo='R04'; descricao=$desc['R04']; pontos=$peso['R04']
            detalhe="Este aparelho ja movimentou $($e.contas_no_aparelho) contas" })
    }
    if ($hora -ge 22 -or $hora -lt 6) {
        [void]$disparadas.Add([ordered]@{ codigo='R05'; descricao=$desc['R05']; pontos=$peso['R05']
            detalhe="Pix feito as $hora h" })
    }
    $score = 0; foreach ($d in $disparadas) { $score += [int]$d.pontos }
    $score = [Math]::Min($score, 100)
    $nivel = if ($score -ge 60) { 'ALTO' } elseif ($score -ge 30) { 'MEDIO' } else { 'BAIXO' }
    return [ordered]@{ score=$score; nivel=$nivel; regras=$disparadas.ToArray(); destino=$e; dispositivo=$disp }
}

# ---------------------------------------------------------------------
# Rotas da API
# ---------------------------------------------------------------------
function Invoke-Rota($metodo, $caminho, $corpo) {
    switch -Regex ("$metodo $caminho") {

        '^GET /api/opcoes$' {
            $contas = @(Invoke-Sql @"
SELECT ct.id, u.apelido, i.nome AS banco FROM conta ct
JOIN usuario u ON u.id = ct.usuario_id JOIN instituicao i ON i.id = ct.instituicao_id
WHERE ct.id <= 50 ORDER BY ct.id;
"@)
            $chaves = @(Invoke-Sql @"
SELECT c.id, c.valor_mascarado AS chave, c.tipo, u.apelido FROM chave_pix c
JOIN conta ct ON ct.id = c.conta_id JOIN usuario u ON u.id = ct.usuario_id
WHERE c.ativa = TRUE ORDER BY c.id;
"@)
            return @{ contas = $contas; chaves = $chaves }
        }

        '^POST /api/verificar$' {
            $o = Get-Inteiro $corpo.origem 'origem'; $k = Get-Inteiro $corpo.chave 'chave'; $v = Get-Valor $corpo.valor
            return (Get-Risco $o $k $v)
        }

        '^POST /api/enviar$' {
            $o = Get-Inteiro $corpo.origem 'origem'; $k = Get-Inteiro $corpo.chave 'chave'; $v = Get-Valor $corpo.valor
            $status = if ($corpo.decisao -eq 'CANCELADA') { 'CANCELADA' } else { 'CONCLUIDA' }
            $risco = Get-Risco $o $k $v
            $prosseguiu = if ($status -eq 'CONCLUIDA') { 'TRUE' } else { 'FALSE' }
            $vs = $v.ToString($inv)
            $codigos = @($risco.regras | ForEach-Object { "'" + $_.codigo + "'" })
            $sqlAlerta = ''
            if ($codigos.Count -gt 0) {
                $sqlAlerta = "INSERT INTO alerta (transacao_id, regra_id, score, usuario_prosseguiu, criado_em) " +
                             "SELECT @tx, id, $($risco.score), $prosseguiu, NOW() FROM regra_risco WHERE codigo IN ($($codigos -join ','));"
            }
            $r = @(Invoke-Sql @"
START TRANSACTION;
INSERT INTO transacao (end_to_end_id, conta_origem_id, chave_destino_id, conta_destino_id,
                       dispositivo_id, valor, data_hora, canal, status, score_risco)
VALUES (CONCAT('A', DATE_FORMAT(NOW(6), '%Y%m%d%H%i%s%f'), LPAD(FLOOR(RAND() * 99999999999), 11, '0')),
        $o, $k, (SELECT conta_id FROM chave_pix WHERE id = $k), $($risco.dispositivo),
        $vs, NOW(), 'APP', '$status', $($risco.score));
SET @tx = LAST_INSERT_ID();
$sqlAlerta
COMMIT;
SELECT id AS transacao_id, end_to_end_id, status, score_risco,
       (SELECT COUNT(*) FROM alerta WHERE transacao_id = @tx) AS alertas_gravados
FROM transacao WHERE id = @tx;
"@)
            return @{ ok = $true; transacao = $r[0]; risco = $risco }
        }

        '^POST /api/denunciar$' {
            $t = Get-Inteiro $corpo.transacao 'transacao'
            $tipos = 'FALSO_PARENTE','FALSA_CENTRAL','LINK_FALSO','FALSA_VENDA','OUTRO'
            if ($tipos -notcontains $corpo.tipo) { throw (New-Object Exception 'VAL|Tipo de golpe invalido.') }
            $dom = 'NULL'
            if ($corpo.dominio) {
                $dd = ([string]$corpo.dominio).Trim().ToLower()
                if ($dd -notmatch '^[a-z0-9][a-z0-9.-]{1,118}$') { throw (New-Object Exception 'VAL|Dominio invalido (use algo como site-falso.com).') }
                $dom = "'$dd'"
            }
            $r = @(Invoke-Sql @"
INSERT INTO denuncia (transacao_id, denunciante_id, chave_denunciada_id, tipo_golpe, dominio_link, data_denuncia, status)
SELECT t.id, co.usuario_id, t.chave_destino_id, '$($corpo.tipo)', $dom, NOW(), 'EM_ANALISE'
FROM transacao t JOIN conta co ON co.id = t.conta_origem_id WHERE t.id = $t;
SELECT ROW_COUNT() AS inseridas, LAST_INSERT_ID() AS denuncia_id;
"@)
            if ([int]$r[0].inseridas -eq 0) { throw (New-Object Exception 'VAL|Pix nao encontrado.') }
            return @{ ok = $true; denuncia_id = $r[0].denuncia_id }
        }

        '^POST /api/denuncia-status$' {
            $id = Get-Inteiro $corpo.id 'id'
            if ('CONFIRMADA','IMPROCEDENTE' -notcontains $corpo.status) { throw (New-Object Exception 'VAL|Status invalido.') }
            Invoke-Sql "UPDATE denuncia SET status = '$($corpo.status)' WHERE id = $id AND status = 'EM_ANALISE'; SELECT ROW_COUNT() AS n;" | Out-Null
            return @{ ok = $true }
        }

        '^GET /api/denuncias$' {
            $lista = Invoke-Sql @"
SELECT d.id, DATE_FORMAT(d.data_denuncia, '%d/%m %H:%i') AS quando, u.apelido AS vitima,
       c.valor_mascarado AS chave, d.tipo_golpe, d.dominio_link, t.valor, d.status, d.transacao_id
FROM denuncia d
JOIN usuario u   ON u.id = d.denunciante_id
JOIN chave_pix c ON c.id = d.chave_denunciada_id
JOIN transacao t ON t.id = d.transacao_id
ORDER BY (d.status = 'EM_ANALISE') DESC, d.id DESC LIMIT 15;
"@
            return @{ denuncias = @($lista) }
        }

        '^GET /api/painel$' {
            $kpi = Invoke-Sql @"
WITH tx_alertada AS (
    SELECT t.id, t.valor, MAX(a.usuario_prosseguiu) AS prosseguiu
    FROM transacao t JOIN alerta a ON a.transacao_id = t.id
    WHERE t.conta_origem_id <= 50
    GROUP BY t.id, t.valor)
SELECT (SELECT COUNT(*) FROM transacao) AS total_pix,
       (SELECT COUNT(*) FROM denuncia WHERE status = 'CONFIRMADA') AS golpes_confirmados,
       (SELECT COUNT(*) FROM denuncia WHERE status = 'EM_ANALISE') AS denuncias_em_analise,
       COUNT(*) AS pix_alertados,
       SUM(prosseguiu = 0) AS desistencias,
       ROUND(100 * AVG(prosseguiu = 0), 1) AS taxa_desistencia,
       SUM(CASE WHEN prosseguiu = 0 THEN valor ELSE 0 END) AS valor_protegido
FROM tx_alertada;
"@
            $semanas = Invoke-Sql @"
SELECT DATE_FORMAT(inicio, '%d/%m') AS semana, evitados, concretizados
FROM (SELECT DATE(t.data_hora - INTERVAL WEEKDAY(t.data_hora) DAY) AS inicio,
             SUM(t.status = 'CANCELADA') AS evitados,
             SUM(t.status = 'CONCLUIDA') AS concretizados
      FROM transacao t
      WHERE t.end_to_end_id LIKE 'F%' OR (t.end_to_end_id LIKE 'A%' AND t.score_risco >= 60)
      GROUP BY inicio) s
ORDER BY inicio;
"@
            $top = Invoke-Sql @"
SELECT c.valor_mascarado AS chave, u.apelido AS titular, COUNT(*) AS golpes, SUM(t.valor) AS prejuizo
FROM denuncia d JOIN chave_pix c ON c.id = d.chave_denunciada_id
JOIN conta ct ON ct.id = c.conta_id JOIN usuario u ON u.id = ct.usuario_id
JOIN transacao t ON t.id = d.transacao_id
WHERE d.status = 'CONFIRMADA'
GROUP BY c.id, c.valor_mascarado, u.apelido ORDER BY golpes DESC, prejuizo DESC LIMIT 5;
"@
            $ultimos = Invoke-Sql @"
SELECT t.id, DATE_FORMAT(t.data_hora, '%d/%m %H:%i') AS quando, uo.apelido AS pagador,
       c.valor_mascarado AS chave, ud.apelido AS recebedor, t.valor, t.status, t.score_risco,
       (SELECT COUNT(*) FROM denuncia d WHERE d.transacao_id = t.id) AS denunciado
FROM transacao t
JOIN conta co ON co.id = t.conta_origem_id JOIN usuario uo ON uo.id = co.usuario_id
JOIN chave_pix c ON c.id = t.chave_destino_id
JOIN conta cd ON cd.id = t.conta_destino_id JOIN usuario ud ON ud.id = cd.usuario_id
ORDER BY t.data_hora DESC, t.id DESC LIMIT 12;
"@
            return @{ kpi = @($kpi)[0]; semanas = @($semanas); top = @($top); ultimos = @($ultimos) }
        }

        default { throw (New-Object Exception "404|Rota nao encontrada: $metodo $caminho") }
    }
}

function Send-Resposta($ctx, [int]$status, [string]$tipo, [byte[]]$bytes) {
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = $tipo
    $ctx.Response.Headers.Add('Cache-Control', 'no-store')
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}
function Send-Json($ctx, [int]$status, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    Send-Resposta $ctx $status 'application/json; charset=utf-8' $utf8.GetBytes($json)
}

# ---------------------------------------------------------------------
# Loop do servidor
# ---------------------------------------------------------------------
$ouvinte = New-Object Net.HttpListener
$ouvinte.Prefixes.Add("http://localhost:$Porta/")
try {
    Invoke-Sql 'SELECT COUNT(*) AS n FROM transacao;' | Out-Null   # testa a conexao
    $ouvinte.Start()
    Write-Host ''
    Write-Host "  PixGuard rodando em  http://localhost:$Porta" -ForegroundColor Green
    Write-Host '  Deixe esta janela aberta durante a apresentacao. Ctrl+C para parar.'
    Write-Host ''
    if (-not $env:PIXGUARD_SEM_NAVEGADOR) { Start-Process "http://localhost:$Porta" }
    while ($ouvinte.IsListening) {
        $tarefa = $ouvinte.GetContextAsync()
        while (-not $tarefa.AsyncWaitHandle.WaitOne(300)) { }
        $ctx = $tarefa.GetAwaiter().GetResult()
        $req = $ctx.Request
        $caminho = $req.Url.AbsolutePath
        try {
            if ($caminho -eq '/' -or $caminho -eq '/index.html') {
                Send-Resposta $ctx 200 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes((Join-Path $pasta 'index.html')))
            }
            elseif ($caminho.StartsWith('/api/')) {
                $corpo = $null
                if ($req.HasEntityBody) {
                    $leitor = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                    $txt = $leitor.ReadToEnd()
                    if ($txt) { $corpo = $txt | ConvertFrom-Json }
                }
                Send-Json $ctx 200 (Invoke-Rota $req.HttpMethod $caminho $corpo)
            }
            else { Send-Resposta $ctx 404 'text/plain' $utf8.GetBytes('Nao encontrado') }
            Write-Host ("{0:HH:mm:ss}  {1} {2}" -f (Get-Date), $req.HttpMethod, $caminho)
        }
        catch {
            $m = $_.Exception.Message
            $partes = $m -split '\|', 4
            if ($partes[0] -eq 'SQL') {
                Send-Json $ctx 422 @{ erro = $(if ($partes[2]) { $partes[2] } else { 'O banco recusou a operacao.' }); erro_mysql = "ERROR $($partes[1]): $($partes[3])" }
            } elseif ($partes[0] -eq 'VAL') {
                Send-Json $ctx 400 @{ erro = $partes[1] }
            } elseif ($partes[0] -eq '404') {
                Send-Json $ctx 404 @{ erro = $partes[1] }
            } else {
                Send-Json $ctx 500 @{ erro = 'Erro interno do servidor.'; detalhe = $m }
            }
            Write-Host ("{0:HH:mm:ss}  {1} {2}  -> {3}" -f (Get-Date), $req.HttpMethod, $caminho, $m) -ForegroundColor Yellow
        }
    }
}
finally {
    if ($ouvinte.IsListening) { $ouvinte.Stop() }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
