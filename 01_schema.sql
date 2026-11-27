-- =====================================================================
-- PixGuard - A3 Analise de Dados e Big Data
-- 01_schema.sql : modelo fisico (MySQL 8.4, InnoDB, utf8mb4)
-- Todos os dados do prototipo sao FICTICIOS.
-- =====================================================================

DROP DATABASE IF EXISTS pixguard;
CREATE DATABASE pixguard CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE pixguard;

-- ---------------------------------------------------------------------
-- Instituicoes participantes do Pix (bancos / fintechs)
-- ---------------------------------------------------------------------
CREATE TABLE instituicao (
    id            SMALLINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    codigo_ispb   CHAR(8)      NOT NULL,
    nome          VARCHAR(80)  NOT NULL,
    CONSTRAINT uq_instituicao_ispb UNIQUE (codigo_ispb),
    CONSTRAINT ck_instituicao_ispb CHECK (codigo_ispb REGEXP '^[0-9]{8}$')
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Usuarios (pseudonimizados: CPF guardado apenas como hash SHA-256)
-- ---------------------------------------------------------------------
CREATE TABLE usuario (
    id              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    cpf_hash        CHAR(64)     NOT NULL,
    apelido         VARCHAR(40)  NOT NULL,
    faixa_etaria    ENUM('18-29','30-44','45-59','60+') NOT NULL,
    uf              CHAR(2)      NOT NULL,
    data_cadastro   DATE         NOT NULL,
    status          ENUM('ATIVO','BLOQUEADO','ENCERRADO') NOT NULL DEFAULT 'ATIVO',
    CONSTRAINT uq_usuario_cpf UNIQUE (cpf_hash),
    CONSTRAINT ck_usuario_uf  CHECK (REGEXP_LIKE(uf, '^[A-Z]{2}$', 'c'))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Contas bancarias
-- ---------------------------------------------------------------------
CREATE TABLE conta (
    id              INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    usuario_id      INT UNSIGNED      NOT NULL,
    instituicao_id  SMALLINT UNSIGNED NOT NULL,
    agencia         CHAR(4)           NOT NULL,
    numero          VARCHAR(12)       NOT NULL,
    tipo            ENUM('CORRENTE','POUPANCA','PAGAMENTO') NOT NULL,
    data_abertura   DATE              NOT NULL,
    CONSTRAINT fk_conta_usuario     FOREIGN KEY (usuario_id)     REFERENCES usuario(id),
    CONSTRAINT fk_conta_instituicao FOREIGN KEY (instituicao_id) REFERENCES instituicao(id),
    CONSTRAINT uq_conta_numero UNIQUE (instituicao_id, agencia, numero)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Chaves Pix (valor real nunca armazenado: so hash + versao mascarada)
-- ---------------------------------------------------------------------
CREATE TABLE chave_pix (
    id               INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    conta_id         INT UNSIGNED NOT NULL,
    tipo             ENUM('CPF','CNPJ','EMAIL','TELEFONE','ALEATORIA') NOT NULL,
    valor_hash       CHAR(64)     NOT NULL,
    valor_mascarado  VARCHAR(40)  NOT NULL,
    criada_em        DATETIME     NOT NULL,
    ativa            BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT fk_chave_conta FOREIGN KEY (conta_id) REFERENCES conta(id),
    CONSTRAINT uq_chave_valor UNIQUE (valor_hash)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Dispositivos (fingerprint do aparelho, em hash)
-- ---------------------------------------------------------------------
CREATE TABLE dispositivo (
    id                 INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    fingerprint_hash   CHAR(64)    NOT NULL,
    sistema            ENUM('ANDROID','IOS','WEB') NOT NULL,
    primeiro_uso       DATETIME    NOT NULL,
    CONSTRAINT uq_dispositivo_fp UNIQUE (fingerprint_hash)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Transacoes Pix (tabela fato, a que mais cresce)
-- ---------------------------------------------------------------------
CREATE TABLE transacao (
    id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    end_to_end_id     CHAR(32)       NOT NULL,
    conta_origem_id   INT UNSIGNED   NOT NULL,
    chave_destino_id  INT UNSIGNED   NOT NULL,
    conta_destino_id  INT UNSIGNED   NOT NULL,
    dispositivo_id    INT UNSIGNED   NOT NULL,
    valor             DECIMAL(12,2)  NOT NULL,
    data_hora         DATETIME       NOT NULL,
    canal             ENUM('APP','INTERNET_BANKING','QR_CODE') NOT NULL,
    status            ENUM('CONCLUIDA','CANCELADA','BLOQUEADA') NOT NULL,
    score_risco       TINYINT UNSIGNED NOT NULL DEFAULT 0,
    CONSTRAINT fk_tx_origem      FOREIGN KEY (conta_origem_id)  REFERENCES conta(id),
    CONSTRAINT fk_tx_chave       FOREIGN KEY (chave_destino_id) REFERENCES chave_pix(id),
    CONSTRAINT fk_tx_destino     FOREIGN KEY (conta_destino_id) REFERENCES conta(id),
    CONSTRAINT fk_tx_dispositivo FOREIGN KEY (dispositivo_id)   REFERENCES dispositivo(id),
    CONSTRAINT uq_tx_e2e     UNIQUE (end_to_end_id),
    CONSTRAINT ck_tx_valor   CHECK (valor > 0 AND valor <= 1000000),
    CONSTRAINT ck_tx_score   CHECK (score_risco BETWEEN 0 AND 100),
    CONSTRAINT ck_tx_contas  CHECK (conta_origem_id <> conta_destino_id)
) ENGINE=InnoDB;

-- Indices pensados nas consultas de negocio:
-- historico de quem envia (perfil do pagador, janela de tempo)
CREATE INDEX ix_tx_origem_data  ON transacao (conta_origem_id, data_hora);
-- quanto uma chave recebeu e de quantas origens (deteccao de "conta laranja")
CREATE INDEX ix_tx_chave_data   ON transacao (chave_destino_id, data_hora);
-- seguir o dinheiro (rede de contas) a partir da conta que recebeu
CREATE INDEX ix_tx_destino_data ON transacao (conta_destino_id, data_hora);
-- relatorios por periodo
CREATE INDEX ix_tx_data         ON transacao (data_hora);

-- ---------------------------------------------------------------------
-- Regras do motor de risco
-- ---------------------------------------------------------------------
CREATE TABLE regra_risco (
    id         TINYINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    codigo     CHAR(3)      NOT NULL,
    descricao  VARCHAR(120) NOT NULL,
    peso       TINYINT UNSIGNED NOT NULL,
    CONSTRAINT uq_regra_codigo UNIQUE (codigo),
    CONSTRAINT ck_regra_peso   CHECK (peso BETWEEN 1 AND 100)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Alertas exibidos ao usuario antes de confirmar o Pix
-- ---------------------------------------------------------------------
CREATE TABLE alerta (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    transacao_id        BIGINT UNSIGNED  NOT NULL,
    regra_id            TINYINT UNSIGNED NOT NULL,
    score               TINYINT UNSIGNED NOT NULL,
    usuario_prosseguiu  BOOLEAN          NOT NULL,
    criado_em           DATETIME         NOT NULL,
    CONSTRAINT fk_alerta_tx    FOREIGN KEY (transacao_id) REFERENCES transacao(id),
    CONSTRAINT fk_alerta_regra FOREIGN KEY (regra_id)     REFERENCES regra_risco(id),
    CONSTRAINT uq_alerta_tx_regra UNIQUE (transacao_id, regra_id),
    CONSTRAINT ck_alerta_score CHECK (score BETWEEN 0 AND 100)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Denuncias de golpe feitas pelas vitimas
-- ---------------------------------------------------------------------
CREATE TABLE denuncia (
    id                BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    transacao_id      BIGINT UNSIGNED NOT NULL,
    denunciante_id    INT UNSIGNED    NOT NULL,
    chave_denunciada_id INT UNSIGNED  NOT NULL,
    tipo_golpe        ENUM('FALSO_PARENTE','FALSA_CENTRAL','LINK_FALSO','FALSA_VENDA','OUTRO') NOT NULL,
    dominio_link      VARCHAR(120)    NULL,
    data_denuncia     DATETIME        NOT NULL,
    status            ENUM('EM_ANALISE','CONFIRMADA','IMPROCEDENTE') NOT NULL DEFAULT 'EM_ANALISE',
    CONSTRAINT fk_den_tx      FOREIGN KEY (transacao_id)        REFERENCES transacao(id),
    CONSTRAINT fk_den_usuario FOREIGN KEY (denunciante_id)      REFERENCES usuario(id),
    CONSTRAINT fk_den_chave   FOREIGN KEY (chave_denunciada_id) REFERENCES chave_pix(id),
    CONSTRAINT uq_den_tx UNIQUE (transacao_id),   -- uma denuncia por transacao (evita duplicata)
    CONSTRAINT ck_den_link CHECK (tipo_golpe <> 'LINK_FALSO' OR dominio_link IS NOT NULL)
) ENGINE=InnoDB;

CREATE INDEX ix_den_chave_status ON denuncia (chave_denunciada_id, status);
