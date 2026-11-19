-- BigQuery (sandbox, EU). Dataset: stan_hunter
-- Column names are Serbian (the domain language); see the glossary in README.md.

CREATE SCHEMA IF NOT EXISTS `stan-hunter.stan_hunter` OPTIONS (location = 'EU');

CREATE TABLE IF NOT EXISTS `stan-hunter.stan_hunter.listings` (
  id                 STRING NOT NULL,  -- "<source>_<source id>", e.g. 4zida_6afb84a9...
  izvor              STRING,           -- source: 4zida | cityexpert | nekretnine | halo | fb:...
  url                STRING,
  naslov             STRING,           -- title
  cena               INT64,            -- monthly rent, EUR
  m2                 FLOAT64,
  sobe               FLOAT64,          -- rooms (0.5 = studio, 1.5, 2, 2.5 ...)
  opstina            STRING,           -- municipality
  naselje            STRING,           -- neighbourhood
  namesten           STRING,           -- furnished: da | polunamešten | ne | nepoznato
  placanje           STRING,           -- payment term (month | day)
  objavljeno         TIMESTAMP,        -- published at (source)
  slika              STRING,           -- image URL (JPEG)
  prosao_filter      BOOL,             -- passes the personal filter
  upisano            TIMESTAMP,        -- ingested at
  depozit_eur        FLOAT64,          -- deposit
  kucni_ljubimci     STRING,           -- pets allowed: da | ne | nepoznato
  provizija          STRING,           -- agency fee, free text (LLM-extracted)
  bez_provizije      STRING,           -- no agency fee: da | ne | nepoznato
  rezije_eur         FLOAT64,          -- monthly utilities estimate (LLM-extracted)
  min_period_meseci  INT64,            -- minimum lease, months (LLM-extracted)
  sumnjiv_oglas      BOOL,             -- scam flag (LLM)
  sumnjiv_razlog     STRING,           -- scam flag reason (LLM)
  oglasivac          STRING,           -- advertiser: agencija | vlasnik
  grejanje           STRING,           -- heating type
  kvalitet           FLOAT64,          -- photo quality 1-5 (Claude vision: mean of condition + furnishing)
  kvalitet_opis      STRING            -- photo description, up to 8 words (Claude vision)
)
PARTITION BY DATE(upisano);

-- English view for analysis / dashboards.
CREATE OR REPLACE VIEW `stan-hunter.stan_hunter.listings_en` AS
SELECT
  id, izvor AS source, url, naslov AS title, cena AS price_eur, m2, sobe AS rooms,
  opstina AS municipality, naselje AS neighbourhood, namesten AS furnished,
  placanje AS payment_term, objavljeno AS published_at, slika AS image_url,
  prosao_filter AS passes_filter, upisano AS ingested_at, depozit_eur AS deposit_eur,
  kucni_ljubimci AS pets_allowed, provizija AS agency_fee, bez_provizije AS no_agency_fee,
  rezije_eur AS utilities_eur, min_period_meseci AS min_lease_months,
  sumnjiv_oglas AS suspicious, sumnjiv_razlog AS suspicious_reason,
  oglasivac AS advertiser, grejanje AS heating,
  kvalitet AS photo_quality, kvalitet_opis AS photo_description
FROM `stan-hunter.stan_hunter.listings`
QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY upisano DESC) = 1;

-- Scoring view: the single source of truth for the 0-100 score.
-- Used by new-listing Telegram messages and by /top. Deterministic: same row -> same score.
CREATE OR REPLACE VIEW `stan-hunter.stan_hunter.listings_scored` AS
WITH base AS (
  SELECT *,
    TRANSLATE(LOWER(CONCAT(IFNULL(opstina, ''), ' ', IFNULL(naselje, ''), ' ', IFNULL(naslov, ''))), 'čćšđž', 'ccsdz') AS mesto
  FROM `stan-hunter.stan_hunter.listings`
  QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY upisano DESC) = 1
),
with_location AS (
  SELECT *,
    -- Location tier 1-5 (my own judgement of the neighbourhoods); outskirts are matched first.
    CASE
      WHEN REGEXP_CONTAINS(mesto, r'mirijevo|mokri lug|kumodraz|medakovic|jajinci|ristin|kaludjerica|zarkovo') THEN 2
      WHEN REGEXP_CONTAINS(mesto, r'vracar|dorcol|stari grad|savski venac|kalenic|crveni krst|krunski venac|centar|senjak|terazije|skupstina') THEN 5
      WHEN REGEXP_CONTAINS(mesto, r'deram|cvetkova|lion|bulbuder|autokomanda|vozdovacka crkva|cubura|belvil|blok 2[1-689]|blok 30') THEN 4
      WHEN REGEXP_CONTAINS(mesto, r'konjarnik|banjica|brace jerkovic|bezanijska kosa|vojvode vlahovica|ustanick') THEN 3
      ELSE 3
    END AS lok
  FROM base
)
SELECT * EXCEPT (mesto),
  ROUND(SAFE_DIVIDE(cena, m2), 2) AS cena_po_m2,
  -- Each part is normalised to 0-1 before weighting; unknown values get a neutral default.
  -- location 30%, photo quality 30% (equal: a great street doesn't fix a bad flat),
  -- price 15% (600 EUR = 0, 300 EUR or less = 1), price/m2 10%, size 10%, furnished 5%
  ROUND(100 * (
      0.30 * (lok - 1) / 4
    + 0.15 * IFNULL(GREATEST(0, LEAST(1, (600 - cena) / 300)), 0)
    + 0.10 * IFNULL(GREATEST(0, LEAST(1, (15 - SAFE_DIVIDE(cena, m2)) / 10)), 0)
    + 0.10 * (0.7 * IFNULL(GREATEST(0, LEAST(1, (m2 - 30) / 50)), 0.5) + 0.3 * IFNULL(GREATEST(0, LEAST(1, (sobe - 1) / 2)), 0.5))
    + 0.05 * CASE namesten WHEN 'da' THEN 1 WHEN 'polunamešten' THEN 0.6 WHEN 'semi' THEN 0.6 WHEN 'ne' THEN 0 ELSE 0.4 END
    + 0.30 * IFNULL(GREATEST(0, LEAST(1, (kvalitet - 1) / 4)), 0.5)
  )) AS ocena
FROM with_location;

-- Useful checks
-- New listings per day and source:
-- SELECT DATE(upisano, 'Europe/Belgrade') AS day, izvor, COUNT(DISTINCT id) AS new_listings,
--        COUNTIF(prosao_filter) AS passing_filter
-- FROM `stan-hunter.stan_hunter.listings` GROUP BY day, izvor ORDER BY day DESC, izvor;
--
-- Load job status:
-- SELECT job_id, state, error_result.message, creation_time
-- FROM `region-eu`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
-- WHERE job_type = 'LOAD' ORDER BY creation_time DESC LIMIT 10;
