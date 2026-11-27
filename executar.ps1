# PixGuard - executa todo o prototipo no MySQL local e salva os resultados
# Uso:  powershell -ExecutionPolicy Bypass -File C:\Projetos\pixguard\executar.ps1
#       powershell -ExecutionPolicy Bypass -File C:\Projetos\pixguard\executar.ps1 -SoloTestes
param([switch]$SoloTestes)

$ErrorActionPreference = 'Stop'
$pasta  = Split-Path -Parent $MyInvocation.MyCommand.Path
$mysql  = 'C:\Program Files\MySQL\MySQL Server 8.4\bin\mysql.exe'
$saida  = Join-Path $pasta 'resultados.txt'
$testes = Join-Path $pasta 'resultados_testes.txt'

$usuario = Read-Host 'Usuario do MySQL (Enter = root)'
if ([string]::IsNullOrWhiteSpace($usuario)) { $usuario = 'root' }
$seguro = Read-Host 'Senha do MySQL' -AsSecureString
$senha  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro))

# arquivo temporario de credenciais (apagado no final)
$cnf = Join-Path $env:TEMP ("pixguard_{0}.cnf" -f [guid]::NewGuid())
"[client]`nuser=$usuario`npassword=`"$senha`"`ndefault-character-set=utf8mb4" |
    Out-File -FilePath $cnf -Encoding ascii
$senha = $null

try {
    $p = ($pasta -replace '\\', '/')
    if (-not $SoloTestes) {
        Write-Host '1/2 Criando banco, carregando dados e rodando as consultas...'
        & $mysql "--defaults-extra-file=$cnf" --table -vv `
            -e "source $p/01_schema.sql; source $p/02_dados.sql; source $p/03_governanca.sql; source $p/04_consultas.sql;" |
            Out-File -FilePath $saida -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw "Erro na etapa 1 (veja a mensagem acima)." }
    }

    Write-Host '2/2 Rodando verificacoes de qualidade (os testes da parte B DEVEM dar erro)...'
    # O arquivo vai pela entrada padrao com --force: cada erro esperado e registrado
    # e o MySQL segue para o proximo teste. Saida e erros vao para arquivos separados.
    $out = Join-Path $env:TEMP 'pixguard_testes_out.txt'
    $err = Join-Path $env:TEMP 'pixguard_testes_err.txt'
    Start-Process -FilePath $mysql -NoNewWindow -Wait `
        -ArgumentList "--defaults-extra-file=`"$cnf`"", '--table', '-vv', '--force' `
        -RedirectStandardInput (Join-Path $pasta '05_qualidade.sql') `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $relatorio = @(
        Get-Content $out
        ''
        '=================================================================='
        ' ERROS RETORNADOS PELO MYSQL NA PARTE B (todos esperados = dado'
        ' invalido rejeitado pelo banco)'
        '=================================================================='
        Get-Content $err
    )
    $relatorio | Out-File -FilePath $testes -Encoding utf8
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue

    Write-Host "Pronto! Resultados em:"
    if (-not $SoloTestes) { Write-Host "  $saida" }
    Write-Host "  $testes"
}
finally {
    Remove-Item $cnf -Force -ErrorAction SilentlyContinue
}
