/***************************************
****** NCCD-specific RxE_Builder ******
***************************************/
--  everything including UNION ALL and below were commented for the table r_to_c (otherwise old  NCCD mappings were taken)

--Add the latest_update and version information to the VOCABULARY table **/
-- update latest_update field to new date
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.SetLatestUpdate( 
	pVocabularyName			=> 'NCCD',
	pVocabularyDate			=> (SELECT vocabulary_date FROM nccd_vocabulary_vesion LIMIT 1),
	pVocabularyVersion		=> (SELECT vocabulary_version FROM nccd_vocabulary_vesion LIMIT 1),
	pVocabularyDevSchema	=> 'dev_nccd'
);
END $_$;

DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.SetLatestUpdate( 
	pVocabularyName			=> 'RxNorm Extension',
	pVocabularyDate			=> CURRENT_DATE,
	pVocabularyVersion		=> 'RxNorm Extension '||CURRENT_DATE,
	pVocabularyDevSchema	=> 'dev_nccd',
	pAppendVocabulary		=> TRUE
);
END $_$;

--drug_concept_stage
ALTER TABLE drug_concept_stage
	ADD CONSTRAINT tmp_dcs_name CHECK (concept_name IS NOT NULL AND concept_name<>''),
	ADD CONSTRAINT tmp_dcs_domain CHECK (domain_id IS NOT NULL AND domain_id<>''),
	ADD CONSTRAINT tmp_dcs_vocabulary CHECK (vocabulary_id IS NOT NULL AND vocabulary_id<>''),
	ADD CONSTRAINT tmp_dcs_class CHECK (concept_class_id IS NOT NULL AND concept_class_id<>''),
	ADD CONSTRAINT tmp_dcs_code CHECK (concept_code IS NOT NULL AND concept_code<>''),
	ADD CONSTRAINT tmp_dcs_reason CHECK (COALESCE(invalid_reason,'D') in ('D','U'));
ALTER TABLE drug_concept_stage 
	DROP CONSTRAINT tmp_dcs_name,
	DROP CONSTRAINT tmp_dcs_domain,
	DROP CONSTRAINT tmp_dcs_vocabulary,
	DROP CONSTRAINT tmp_dcs_class,
	DROP CONSTRAINT tmp_dcs_code,
	DROP CONSTRAINT tmp_dcs_reason;

--internal_relationship_stage
ALTER TABLE internal_relationship_stage
	ADD CONSTRAINT tmp_irs_code1 CHECK (concept_code_1 IS NOT NULL AND concept_code_1<>''),
	ADD CONSTRAINT tmp_irs_code2 CHECK (concept_code_2 IS NOT NULL AND concept_code_2<>'');
ALTER TABLE internal_relationship_stage 
	DROP CONSTRAINT tmp_irs_code1,
	DROP CONSTRAINT tmp_irs_code2;

--relationship_to_concept
ALTER TABLE relationship_to_concept
	ADD CONSTRAINT tmp_rtc_code1 CHECK (concept_code_1 IS NOT NULL AND concept_code_1<>''),
	ADD CONSTRAINT tmp_rtc_id2 CHECK (concept_id_2 IS NOT NULL),
	ADD CONSTRAINT tmp_rtc_float CHECK (pg_typeof(conversion_factor)='numeric'::regtype),
	ADD CONSTRAINT tmp_rtc_int2 CHECK (pg_typeof(precedence)='smallint'::regtype);
ALTER TABLE relationship_to_concept 
	DROP CONSTRAINT tmp_rtc_code1,
	DROP CONSTRAINT tmp_rtc_id2,
	DROP CONSTRAINT tmp_rtc_float,
	DROP CONSTRAINT tmp_rtc_int2;

--pc_stage
ALTER TABLE pc_stage
	ADD CONSTRAINT tmp_pcs_pack CHECK (pack_concept_code IS NOT NULL AND pack_concept_code<>''),
	ADD CONSTRAINT tmp_pcs_drug CHECK (drug_concept_code IS NOT NULL AND drug_concept_code<>''),
	ADD CONSTRAINT tmp_pcs_amount_int2 CHECK (pg_typeof(amount)='smallint'::regtype),
	ADD CONSTRAINT tmp_pcs_bx_int2 CHECK (pg_typeof(box_size)='smallint'::regtype);
ALTER TABLE pc_stage
	DROP CONSTRAINT tmp_pcs_pack,
	DROP CONSTRAINT tmp_pcs_drug,
	DROP CONSTRAINT tmp_pcs_amount_int2,
	DROP CONSTRAINT tmp_pcs_bx_int2;

--ds_stage
ALTER TABLE ds_stage
	ADD CONSTRAINT tmp_dss_drug CHECK (drug_concept_code IS NOT NULL AND drug_concept_code<>''),
	ADD CONSTRAINT tmp_dss_ing CHECK (ingredient_concept_code IS NOT NULL AND ingredient_concept_code<>''),
	ADD CONSTRAINT tmp_dss_float1 CHECK (pg_typeof(amount_value)='numeric'::regtype),
	ADD CONSTRAINT tmp_dss_float2 CHECK (pg_typeof(numerator_value)='numeric'::regtype),
	ADD CONSTRAINT tmp_dss_float3 CHECK (pg_typeof(denominator_value)='numeric'::regtype),
	ADD CONSTRAINT tmp_dss_int2 CHECK (pg_typeof(box_size)='smallint'::regtype);
ALTER TABLE ds_stage
	DROP CONSTRAINT tmp_dss_drug,
	DROP CONSTRAINT tmp_dss_ing,
	DROP CONSTRAINT tmp_dss_float1,
	DROP CONSTRAINT tmp_dss_float2,
	DROP CONSTRAINT tmp_dss_float3,
	DROP CONSTRAINT tmp_dss_int2;

/*end QA*/

-- Add existing mappings from previous runs.
DROP TABLE IF EXISTS r_to_c;
--CREATE OR replace VIEW r_to_c AS
CREATE UNLOGGED TABLE r_to_c AS
SELECT r.*
FROM relationship_to_concept r
JOIN concept c ON c.concept_id = r.concept_id_2
	AND c.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension',
		'UCUM'
		);
-- prevent entry of old mappings
/*UNION ALL

SELECT DISTINCT c1.concept_code AS concept_code_1,
	c1.vocabulary_id AS vocabulary_id_1,
	r.concept_id_2 AS concept_id_2,
	1 AS precedence,
	NULL::NUMERIC AS conversion_factor
FROM concept c1
JOIN concept_relationship r ON r.concept_id_1 = c1.concept_id
	AND r.relationship_id IN (
		'Maps to',
		'Source - RxNorm eq'
		)
	AND r.invalid_reason IS NULL
JOIN concept c2 ON c2.concept_id = r.concept_id_2
	AND c2.invalid_reason IS NULL
WHERE c1.vocabulary_id = (
		SELECT dcs.vocabulary_id
		FROM drug_concept_stage dcs LIMIT 1
		)
	AND c2.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
	AND c2.concept_class_id IN (
		'Ingredient',
		'Dose Form',
		'Brand Name',
		'Supplier'
		)
	AND NOT EXISTS (
		SELECT 1
		FROM relationship_to_concept rtc
		WHERE rtc.concept_code_1 = c1.concept_code
		); */

CREATE INDEX idx_rtc ON r_to_c (concept_code_1, concept_id_2);
ANALYZE r_to_c;

/*****************************************************************************************************************************************************
* 1. Prepare drug components for new vocabularies: Create unique list and for each drug enumerate. This allows to create a single row for each drug. *
*****************************************************************************************************************************************************/

-- Sequence for unique q_ds
DROP SEQUENCE IF EXISTS ds_seq;
CREATE SEQUENCE ds_seq INCREMENT BY 1 START WITH 1 NO CYCLE CACHE 20;
-- Sequence for temporary XXX concept codes
DROP SEQUENCE IF EXISTS xxx_seq;
CREATE SEQUENCE xxx_seq INCREMENT BY 1 START WITH 1 NO CYCLE CACHE 20;
-- Sequence for non-existing concept_ids for extension concepts 
DROP SEQUENCE IF EXISTS extension_id;
CREATE SEQUENCE extension_id INCREMENT BY -1 START WITH -1 NO CYCLE CACHE 20;

/*****************************
* 2. Collect atributes for q *
*****************************/

-- Create table with all drug concept codes linked to the codes of the ingredients (rather than full dose components)
DROP TABLE IF EXISTS q_ing;
CREATE UNLOGGED TABLE q_ing AS
SELECT dcs1.concept_code AS concept_code,
	dcs2.concept_code AS i_code
FROM drug_concept_stage dcs1
JOIN internal_relationship_stage irs ON irs.concept_code_1 = dcs1.concept_code
JOIN drug_concept_stage dcs2 ON dcs2.concept_code = irs.concept_code_2
	AND dcs2.concept_class_id = 'Ingredient'
WHERE dcs1.concept_class_id = 'Drug Product'
	AND dcs1.domain_id = 'Drug' -- Drug Products

UNION

SELECT drug_concept_code AS concept_code,
	ingredient_concept_code AS i_code
FROM ds_stage; -- just in case, won't hurt if the internal_relationship table forgot something

-- Create distinct version of drug_strength in concentration notation (no quant).
-- Replace nulls with 0 and ' '

-- Create a rounded version of ds_stage
DROP TABLE IF EXISTS ds_rounded;
CREATE UNLOGGED TABLE ds_rounded AS
SELECT s0.drug_concept_code,
	s0.ingredient_concept_code,
	CASE s0.amount_value
		WHEN 0
			THEN 0
		ELSE ROUND(s0.amount_value, (3 - FLOOR(LOG(s0.amount_value)) - 1)::INT)
		END AS amount_value,
	s0.amount_unit,
	CASE s0.numerator_value
		WHEN 0
			THEN 0
		ELSE ROUND(s0.numerator_value, (3 - FLOOR(LOG(s0.numerator_value)) - 1)::INT)
		END AS numerator_value,
	s0.numerator_unit,
	s0.denominator_unit
FROM (
	SELECT ds.drug_concept_code,
		ds.ingredient_concept_code,
		COALESCE(ds.amount_value, 0) AS amount_value,
		COALESCE(ds.amount_unit, ' ') AS amount_unit,
		CASE 
			WHEN rtc.concept_id_2 IN (
					8554,
					9325,
					9324
					)
				THEN numerator_value -- % and homeopathics is already a fixed concentration, no need to adjust to volume
			WHEN COALESCE(ds.numerator_value, 0) = 0
				THEN 0
			ELSE ds.numerator_value / COALESCE(ds.denominator_value, 1) -- turn into concentration as basis for comparison.
			END AS numerator_value,
		COALESCE(ds.numerator_unit, ' ') AS numerator_unit,
		CASE -- denominator unit should be undefined for % and the homeopathics
			WHEN rtc.concept_id_2 IN (
					8554,
					9325,
					9324
					)
				THEN NULL -- % and homeopathics is already a fixed concentration, no need to adjust to volume
			ELSE COALESCE(ds.denominator_unit, ' ')
			END AS denominator_unit
	FROM ds_stage ds
	LEFT JOIN r_to_c rtc ON rtc.concept_code_1 = ds.numerator_unit
		AND COALESCE(rtc.precedence, 1) = 1 -- to get the q version of % and homeopathics
	) AS s0;

-- Create unique dose table
DROP TABLE IF EXISTS q_uds;
CREATE UNLOGGED TABLE q_uds (
	ds_code VARCHAR(50),
	ingredient_concept_code VARCHAR(50),
	amount_value NUMERIC,
	amount_unit VARCHAR(50),
	numerator_value NUMERIC,
	numerator_unit VARCHAR(50),
	denominator_unit VARCHAR(50)
	);

INSERT INTO q_uds
SELECT NEXTVAL('ds_seq')::VARCHAR AS ds_code,
	q_ds.*
FROM (
	SELECT DISTINCT ingredient_concept_code,
		amount_value,
		amount_unit,
		numerator_value,
		numerator_unit,
		denominator_unit
	FROM ds_rounded
	ORDER BY ingredient_concept_code,
		amount_value,
		amount_unit,
		numerator_value,
		numerator_unit,
		denominator_unit --just for sequence repeatability
	) q_ds;

-- Create table with all drug concept codes linked to the above unique components 
DROP TABLE IF EXISTS q_ds;
CREATE UNLOGGED TABLE q_ds AS
SELECT drug_concept_code AS concept_code,
	ingredient_concept_code AS i_code,
	DENSE_RANK() OVER (
		ORDER BY ingredient_concept_code,
			amount_value,
			amount_unit,
			numerator_value,
			numerator_unit,
			denominator_unit
		)::VARCHAR AS ds_code,
	denominator_unit AS quant_unit
FROM ds_rounded;

CREATE INDEX idx_q_ds_dscode ON q_ds (ds_code);
CREATE INDEX idx_q_ds_concode ON q_ds (concept_code);
ANALYZE q_ds;

-- Turn gases into percent if they are in mg/mg or mg/mL
UPDATE q_uds q
SET numerator_value = CASE 
		WHEN concept_id_2 = 8576
			THEN numerator_value * 100
		ELSE numerator_value / 10
		END,
	numerator_unit = (
		SELECT concept_code_1
		FROM r_to_c
		WHERE concept_id_2 = 8554
			AND precedence = 1
		), -- set to percent
	denominator_unit = NULL
FROM (
	SELECT q2.ds_code,
		rd.concept_id_2
	FROM internal_relationship_stage irs
	JOIN r_to_c rc ON rc.concept_code_1 = irs.concept_code_2
	JOIN q_ds q1 ON q1.concept_code = irs.concept_code_1
	JOIN q_uds q2 ON q2.ds_code = q1.ds_code
	JOIN r_to_c rn ON rn.concept_code_1 = q2.numerator_unit
		AND rn.precedence = 1 -- translate to Standard for numerator
	JOIN r_to_c rd ON rd.concept_code_1 = q2.denominator_unit
		AND rd.precedence = 1 -- translate to Standard for denominator
	WHERE rc.concept_id_2 IN (
			19082258,
			40228366
			) -- Gas for Inhalation, Gas
		AND rn.concept_id_2 = 8576 /*mg*/
		AND rd.concept_id_2 IN (
			8576 /*mg*/,
			8587 /*mL*/
			)
	) i
WHERE i.ds_code = q.ds_code;

-- Create table with the combination of components for each drug concept delimited by '-'
-- Contains both ingredient combos and ds combos. For Drug Forms d_combo=' '
DROP TABLE IF EXISTS q_combo;
CREATE UNLOGGED TABLE q_combo AS
SELECT concept_code,
	STRING_AGG(i_code, '-' ORDER BY i_code) AS i_combo,
	STRING_AGG(ds_code, '-' ORDER BY LPAD(ds_code,10,'0')) AS d_combo --LPAD for 'old' sorting when ds_code was an integer
FROM q_ds
GROUP BY concept_code;

-- Add Drug Forms, which have no entry in ds_stage. Shouldn't exist, unless there are singleton Drug Forms with no descendants.
-- build the i_combos from scratch, no equivalent to q_ds
INSERT INTO q_combo
SELECT dcs1.concept_code,
	STRING_AGG(dcs2.concept_code, '-' ORDER BY dcs2.concept_code) AS i_combo,
	' ' AS d_combo
FROM drug_concept_stage dcs1
JOIN internal_relationship_stage r ON r.concept_code_1 = dcs1.concept_code
JOIN drug_concept_stage dcs2 ON dcs2.concept_code = r.concept_code_2
	AND dcs2.concept_class_id = 'Ingredient'
WHERE dcs1.concept_code IN (
		SELECT concept_code
		FROM drug_concept_stage dcs_int
		WHERE dcs_int.domain_id = 'Drug'
			AND dcs_int.concept_class_id = 'Drug Product'
		
		EXCEPT
		
		SELECT drug_concept_code
		FROM ds_stage
		)
	AND NOT EXISTS (
		SELECT 1
		FROM q_combo q
		WHERE q.concept_code = dcs1.concept_code
		)
GROUP BY dcs1.concept_code;

CREATE INDEX idx_q_combo ON q_combo (concept_code);
ANALYZE q_combo;

-- Create table with Quantity Factor information for each drug (if exists), not rounded
DROP TABLE IF EXISTS q_quant;
CREATE UNLOGGED TABLE q_quant AS
SELECT DISTINCT drug_concept_code AS concept_code,
	ROUND(denominator_value, (3 - FLOOR(LOG(denominator_value)) - 1)::INT) AS value, -- round quant value
	denominator_unit AS unit
FROM ds_stage
WHERE COALESCE(denominator_value, 0) <> 0
	AND COALESCE(numerator_value, 0) <> 0;

CREATE INDEX idx_q_quant ON q_quant (concept_code);
ANALYZE q_quant;

-- Create table with Dose Form information for each drug (if exists)
DROP TABLE IF EXISTS q_df;
CREATE UNLOGGED TABLE q_df AS
SELECT DISTINCT irs.concept_code_1 AS concept_code,
	dcs.concept_code AS df_code -- distinct only because source may contain duplicated maps
FROM internal_relationship_stage irs
JOIN drug_concept_stage dcs ON dcs.concept_code = irs.concept_code_2
	AND dcs.concept_class_id = 'Dose Form'
	AND dcs.domain_id = 'Drug'; -- Dose Form of a drug

CREATE INDEX idx_q_df ON q_df (concept_code);
ANALYZE q_df;

-- Create table with Brand Name information for each drug including packs (if exists)
DROP TABLE IF EXISTS q_bn;
CREATE UNLOGGED TABLE q_bn AS
SELECT DISTINCT irs.concept_code_1 AS concept_code,
	dcs.concept_code AS bn_code -- distinct only because source contains duplicated maps
FROM internal_relationship_stage irs
JOIN drug_concept_stage dcs ON dcs.concept_code = irs.concept_code_2
	AND dcs.concept_class_id = 'Brand Name'
	AND dcs.domain_id = 'Drug';-- Brand Name of a drug

CREATE INDEX idx_q_bn ON q_bn (concept_code);
ANALYZE q_bn;

-- Create table with Suppliers (manufacturers) including packs
DROP TABLE IF EXISTS q_mf;
CREATE UNLOGGED TABLE q_mf AS
SELECT DISTINCT irs.concept_code_1 AS concept_code,
	dcs.concept_code AS mf_code -- distinct only because source contains duplicated maps
FROM internal_relationship_stage irs
JOIN drug_concept_stage dcs ON dcs.concept_code = irs.concept_code_2
	AND dcs.concept_class_id = 'Supplier'
	AND dcs.domain_id = 'Drug';-- Supplier of a drug

CREATE INDEX idx_q_mf ON q_mf (concept_code);
ANALYZE q_mf;

-- Create table with Box Size information
DROP TABLE IF EXISTS q_bs;
CREATE UNLOGGED TABLE q_bs AS
SELECT DISTINCT drug_concept_code AS concept_code,
	box_size AS bs
FROM ds_stage
WHERE box_size IS NOT NULL;

CREATE INDEX idx_q_bs ON q_bs (concept_code);
ANALYZE q_bs;

/**************************************************************************
* 4. Create the list of all all existing q products in attribute notation *
***************************************************************************/

-- Duplication rule 1: More than one definition per concept_code is illegal
-- Duplication rule 2: More than one concept_code per definition is allowed.

-- Collect all input drugs and create master matrix, including assignment of concept_classes
DROP TABLE IF EXISTS q_existing;
CREATE UNLOGGED TABLE q_existing AS
-- Marketed Product
SELECT c.concept_code, COALESCE(q3.value, 0) AS quant_value, COALESCE(q3.unit, ' ') AS quant_unit, c.i_combo, c.d_combo, q1.df_code, COALESCE(q4.bn_code, ' ') AS bn_code, COALESCE(q5.bs, 0) AS bs, q2.mf_code AS mf_code, 'Marketed Product' AS concept_class_id
FROM q_combo c
JOIN q_df q1 ON q1.concept_code = c.concept_code
JOIN q_mf q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_quant q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bn q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_bs q5 ON q5.concept_code = c.concept_code
WHERE c.d_combo <> ' '

UNION ALL

-- Quant Branded Box
SELECT c.concept_code, q1.value AS quant_value, q1.unit AS quant_unit, c.i_combo, c.d_combo, q2.df_code, q3.bn_code, q4.bs, ' ' AS mf_code, 'Quant Branded Box' AS concept_class_id
FROM q_combo c
JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE c.d_combo <> ' '
	AND q5.mf_code IS NULL

UNION ALL

-- Quant Clinical Box
SELECT c.concept_code, q1.value AS quant_value, q1.unit AS quant_unit, c.i_combo, c.d_combo, q2.df_code, ' ' AS bn_code, q4.bs, ' ' AS mf_code, 'Quant Clinical Box' AS concept_class_id
FROM q_combo c
JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE c.d_combo <> ' '
	AND q3.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Branded Drug Box
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, q3.bn_code, q4.bs, ' ' AS mf_code, 'Branded Drug Box' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q5.mf_code IS NULL

UNION ALL

-- Clinical Drug Box
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, ' ' AS bn_code, q4.bs, ' ' AS mf_code, 'Clinical Drug Box' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q3.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Quant Branded Drug
SELECT c.concept_code, q1.value AS quant_value, q1.unit AS quant_unit, c.i_combo, c.d_combo, q2.df_code, q3.bn_code, 0 AS bs, ' ' AS mf_code, 'Quant Branded Drug' AS concept_class_id
FROM q_combo c
JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE c.d_combo <> ' '
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Quant Clinical Drug
SELECT c.concept_code, q1.value AS quant_value, q1.unit AS quant_unit, c.i_combo, c.d_combo, q2.df_code, ' ' AS bn_code, 0 AS bs, ' ' AS mf_code, 'Quant Clinical Drug' AS concept_class_id
FROM q_combo c
JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE c.d_combo <> ' '
	AND q3.concept_code IS NULL
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Branded Drug
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, q3.bn_code, 0 AS bs, ' ' AS mf_code, 'Branded Drug' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Clinical Drug
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, ' ' AS bn_code, 0 AS bs, ' ' AS mf_code, 'Clinical Drug' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q3.concept_code IS NULL
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Branded Drug Form
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, q3.bn_code, 0 AS bs, ' ' AS mf_code, 'Branded Drug Form' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo = ' '
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Clinical Drug Form
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, q2.df_code, ' ' AS bn_code, 0 AS bs, ' ' AS mf_code, 'Clinical Drug Form' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo = ' '
	AND q3.concept_code IS NULL
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL

UNION ALL

-- Branded Drug Component
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, ' ' AS df_code, q3.bn_code, 0 AS bs, ' ' AS mf_code, 'Branded Drug Comp' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
LEFT JOIN q_df q2 ON q2.concept_code = c.concept_code
JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q2.concept_code IS NULL
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL -- denominator_value is ignored

UNION ALL

-- Clinical Drug Component 
SELECT c.concept_code, 0 AS quant_value, ' ' AS quant_unit, c.i_combo, c.d_combo, ' ' AS df_code, ' ' AS bn_code, 0 AS bs, ' ' AS mf_code, 'Clinical Drug Comp' AS concept_class_id
FROM q_combo c
LEFT JOIN q_quant q1 ON q1.concept_code = c.concept_code
LEFT JOIN q_df q2 ON q2.concept_code = c.concept_code
LEFT JOIN q_bn q3 ON q3.concept_code = c.concept_code
LEFT JOIN q_bs q4 ON q4.concept_code = c.concept_code
LEFT JOIN q_mf q5 ON q5.concept_code = c.concept_code
WHERE q1.concept_code IS NULL
	AND c.d_combo <> ' '
	AND q2.concept_code IS NULL
	AND q3.concept_code IS NULL
	AND q4.concept_code IS NULL
	AND q5.mf_code IS NULL;

/******************************
* 4. Collect atributes for r  *
******************************/
-- Create xxx-type codes for r ingredients, so we can add them
DROP TABLE IF EXISTS ing_stage;
CREATE UNLOGGED TABLE ing_stage AS
SELECT 'XXX' || NEXTVAL('xxx_seq') AS i_code,
	concept_id AS i_id
FROM (
	SELECT *
	FROM concept
	WHERE vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND concept_class_id = 'Ingredient'
	ORDER BY concept_id --just for sequence repeatability
	) AS s0;

CREATE INDEX idx_ing_stage ON ing_stage (i_id);
ANALYZE ing_stage;

-- Create table with all drug concepts linked to the codes of the ingredients (rather than full dose components)
DROP TABLE IF EXISTS r_ing;
CREATE UNLOGGED TABLE r_ing AS
SELECT *
FROM (
	SELECT de.concept_id AS concept_id,
		an.concept_id AS i_id
	FROM concept_ancestor a
	JOIN concept an ON a.ancestor_concept_id = an.concept_id
		AND an.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND an.concept_class_id = 'Ingredient'
	JOIN concept de ON de.concept_id = a.descendant_concept_id
		AND de.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND de.concept_class_id IN (
			'Clinical Drug Form',
			'Branded Drug Form'
			)
	
	UNION
	
	SELECT ds.drug_concept_id AS concept_id,
		ds.ingredient_concept_id AS i_id
	FROM drug_strength ds -- just in case, won't hurt if the internal_relationship table forgot something
	JOIN concept c ON c.concept_id = ds.drug_concept_id
		AND c.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
	WHERE ds.drug_concept_id <> ds.ingredient_concept_id -- in future, ingredients will also have records, where drug and ingredient ids are the same
	) AS s0
JOIN ing_stage USING (i_id);

-- Create table with unique dosages
DROP TABLE IF EXISTS r_uds;
CREATE UNLOGGED TABLE r_uds AS
SELECT NEXTVAL('ds_seq')::VARCHAR AS ds_code,
	ds.*
FROM (
	SELECT *
	FROM (
		-- reuse the same sequence for q_ds and r_ds
		SELECT DISTINCT i.i_code, -- use internal codes instead of concept id, so new ones can be added later.
			ds.ingredient_concept_id, -- still keep it for faster creation of r_ds, but don't use it otherwise
			COALESCE(ds.amount_value, 0) AS amount_value,
			COALESCE(ds.amount_unit_concept_id, 0) AS amount_unit_concept_id,
			COALESCE(ds.numerator_value, 0) AS numerator_value,
			COALESCE(ds.numerator_unit_concept_id, 0) AS numerator_unit_concept_id,
			CASE -- % and homeopathics should have an undefined denominator_unit. r_quant will eventually get it from ds_stage.
				WHEN ds.numerator_unit_concept_id IN (
						8554,
						9325,
						9324
						)
					THEN NULL
				ELSE COALESCE(ds.denominator_unit_concept_id, 0)
				END AS denominator_unit_concept_id
		FROM drug_strength ds
		JOIN ing_stage i ON i.i_id = ds.ingredient_concept_id
		JOIN concept c ON c.concept_id = ds.drug_concept_id
			AND c.vocabulary_id IN (
				'RxNorm',
				'RxNorm Extension'
				)
			AND c.concept_class_id NOT IN (
				'Ingredient',
				'Clinical Drug Form',
				'Branded Drug Form'
				) -- exclude these, since they are now part of drug_strength, but don't have strength information
		WHERE ds.denominator_value IS NULL -- don't use Quant Drugs, because their numerator value is rounded in drug_strength. Use the non-quantified version instead
		) s0
	ORDER BY s0.i_code, --just for sequence repeatability
		s0.ingredient_concept_id,
		s0.amount_value,
		s0.amount_unit_concept_id,
		s0.numerator_value,
		s0.numerator_unit_concept_id,
		s0.denominator_unit_concept_id
	) ds;

-- Create table with all drug concept codes linked to the above unique components 
DROP TABLE IF EXISTS r_ds;
CREATE UNLOGGED TABLE r_ds AS
	WITH w_uds AS (
			SELECT ds.drug_concept_id,
				ds.ingredient_concept_id,
				i.i_code,
				COALESCE(ds.amount_value, 0) AS amount_value,
				COALESCE(ds.amount_unit_concept_id, 0) AS amount_unit_concept_id,
				COALESCE(ds.numerator_value, 0) AS numerator_value,
				COALESCE(ds.numerator_unit_concept_id, 0) AS numerator_unit_concept_id,
				CASE -- % and homeopathics should have an undefined denominator_unit. r_quant will get it eventually from ds_stage
					WHEN ds.numerator_unit_concept_id IN (
							8554,
							9325,
							9324
							)
						THEN NULL
					ELSE COALESCE(ds.denominator_unit_concept_id, 0)
					END AS denominator_unit_concept_id
			FROM drug_strength ds
			JOIN ing_stage i ON i.i_id = ds.ingredient_concept_id
			WHERE ds.denominator_value IS NULL -- don't use Quant Drugs, because their numerator value is rounded in drug_strength. Use the non-quantified version instead
			)

SELECT DISTINCT ds.drug_concept_id AS concept_id, uds.i_code, uds.ds_code, uds.denominator_unit_concept_id AS quant_unit_id
FROM (
	SELECT u.drug_concept_id, u.ingredient_concept_id, u.amount_value, u.amount_unit_concept_id, u.numerator_value, u.numerator_unit_concept_id, u.denominator_unit_concept_id
	FROM w_uds u
	JOIN concept c ON c.concept_id = u.drug_concept_id
		AND c.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND c.concept_class_id NOT IN (
			'Ingredient',
			'Clinical Drug Form',
			'Branded Drug Form'
			) -- exclude these, since they are now part of drug_strength, but don't have strength information
	
	UNION ALL -- get the drug strength information for the quantified versions of a drug from the non-quantified
	
	SELECT cr.concept_id_2, u.ingredient_concept_id, u.amount_value, u.amount_unit_concept_id, u.numerator_value, u.numerator_unit_concept_id, u.denominator_unit_concept_id
	FROM w_uds u
	JOIN concept c1 ON c1.concept_id = u.drug_concept_id
		AND c1.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND c1.invalid_reason IS NULL
	JOIN concept_relationship cr ON cr.concept_id_1 = c1.concept_id
		AND cr.invalid_reason IS NULL
		AND cr.relationship_id = 'Has quantified form'
	JOIN concept c2 ON c2.concept_id = cr.concept_id_2
		AND c2.invalid_reason IS NULL -- check that resulting quantified is valid
	
	UNION ALL -- get the drug strength information for Marketed Products from the non-quantified version of the non-marketed quant drug
	
	SELECT cr2.concept_id_2, u.ingredient_concept_id, u.amount_value, u.amount_unit_concept_id, u.numerator_value, u.numerator_unit_concept_id, u.denominator_unit_concept_id
	FROM w_uds u
	JOIN concept c1 ON c1.concept_id = u.drug_concept_id
		AND c1.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND c1.invalid_reason IS NULL
	JOIN concept_relationship cr1 ON cr1.concept_id_1 = c1.concept_id
		AND cr1.invalid_reason IS NULL
		AND cr1.relationship_id = 'Has quantified form'
	JOIN concept c2 ON c2.concept_id = cr1.concept_id_2
		AND c2.invalid_reason IS NULL -- check that resulting quantified is valid
	JOIN concept_relationship cr2 ON cr2.concept_id_1 = cr1.concept_id_2
		AND cr2.invalid_reason IS NULL
		AND cr2.relationship_id = 'Has marketed form'
	JOIN concept f ON f.concept_id = cr2.concept_id_2
		AND f.invalid_reason IS NULL -- check that resulting marketed is valid
	) ds
JOIN r_uds uds USING (ingredient_concept_id, amount_value, amount_unit_concept_id, numerator_value, numerator_unit_concept_id)
WHERE COALESCE(ds.denominator_unit_concept_id, -1) = COALESCE(uds.denominator_unit_concept_id, -1);-- match nulls for % and homeopathics

--create index idx_r_ds_dscode on r_ds (ds_code);
--create index idx_r_ds_concode on r_ds (concept_id);
--analyze r_ds;

-- Create table with the combination of ds components for each drug concept delimited by '-'
-- Add corresponding ingredient combos
DROP TABLE IF EXISTS r_combo;
CREATE UNLOGGED TABLE r_combo AS
SELECT concept_id,
	STRING_AGG(i_code, '-' ORDER BY i_code) AS i_combo,
	STRING_AGG(ds_code, '-' ORDER BY LPAD(ds_code, 10, '0')) AS d_combo
FROM r_ds
GROUP BY concept_id;

-- Add Drug Forms, which have no entry in ds_stage. 
INSERT INTO r_combo
SELECT concept_id,
	STRING_AGG(i_code, '-' ORDER BY i_code) AS i_combo,
	' ' AS d_combo
FROM r_ing i
WHERE NOT EXISTS (
		SELECT 1
		FROM r_combo r
		WHERE r.concept_id = i.concept_id
		)
GROUP BY concept_id;

CREATE INDEX idx_r_combo ON r_combo (concept_id);
ANALYZE r_combo;

-- Create table with Quantity Factor information for each drug (if exists), not rounded
DROP TABLE IF EXISTS r_quant;
CREATE UNLOGGED TABLE r_quant AS
SELECT DISTINCT drug_concept_id AS concept_id,
	denominator_value AS value,
	denominator_unit_concept_id AS unit_id
FROM drug_strength ds
JOIN concept c ON c.concept_id = ds.drug_concept_id
	AND c.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
WHERE ds.denominator_value IS NOT NULL
	AND ds.numerator_value IS NOT NULL
	AND ds.drug_concept_id <> ds.ingredient_concept_id;

CREATE INDEX idx_r_quant ON r_quant (concept_id);
ANALYZE r_quant;


-- Create table with Dose Form information for each drug (if exists)
DROP TABLE IF EXISTS r_df;
CREATE UNLOGGED TABLE r_df AS
SELECT cr.concept_id_1 AS concept_id,
	cr.concept_id_2 AS df_id
FROM concept_relationship cr
JOIN concept c1 ON c1.concept_id = cr.concept_id_1
	AND c1.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
	AND c1.standard_concept = 'S'
JOIN concept c2 ON c2.concept_id = cr.concept_id_2
	AND c2.concept_class_id = 'Dose Form'
	AND c2.invalid_reason IS NULL
WHERE cr.invalid_reason IS NULL
	AND cr.relationship_id = 'RxNorm has dose form';

CREATE INDEX idx_r_df ON r_df (concept_id);
ANALYZE r_df;

-- Create table with Brand Name information for each drug (if exists)
DROP TABLE IF EXISTS r_bn;
CREATE UNLOGGED TABLE r_bn AS
SELECT cr.concept_id_1 AS concept_id,
	cr.concept_id_2 AS bn_id
FROM concept_relationship cr
JOIN concept c1 ON c1.concept_id = cr.concept_id_1
	AND c1.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
	AND c1.standard_concept = 'S'
JOIN concept c2 ON c2.concept_id = cr.concept_id_2
	AND c2.concept_class_id = 'Brand Name'
	AND c2.invalid_reason IS NULL
WHERE cr.invalid_reason IS NULL
	AND cr.relationship_id = 'Has brand name';

CREATE INDEX idx_r_bn ON r_bn (concept_id);
ANALYZE r_bn;

-- Create table with Suppliers (manufacturers)
DROP TABLE IF EXISTS r_mf;
CREATE UNLOGGED TABLE r_mf AS
SELECT cr.concept_id_1 AS concept_id,
	cr.concept_id_2 AS mf_id
FROM concept_relationship cr
JOIN concept c1 ON c1.concept_id = cr.concept_id_1
	AND c1.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
	AND c1.standard_concept = 'S'
JOIN concept c2 ON c2.concept_id = cr.concept_id_2
	AND c2.concept_class_id = 'Supplier'
	AND c2.invalid_reason IS NULL
WHERE cr.invalid_reason IS NULL
	AND cr.relationship_id = 'Has supplier';
	
CREATE INDEX idx_r_mf ON r_mf (concept_id);
ANALYZE r_mf;

-- Create table with Box Size information 
DROP TABLE IF EXISTS r_bs;
CREATE UNLOGGED TABLE r_bs AS
SELECT DISTINCT drug_concept_id AS concept_id,
	box_size AS bs
FROM drug_strength
JOIN concept d ON d.concept_id = drug_concept_id
	AND d.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		) -- XXXX remove aftr DPD is gone
WHERE box_size IS NOT NULL;

CREATE INDEX idx_r_bs ON r_bs (concept_id);
ANALYZE r_bs;


/**************************************************************************
* 5. Create the list of all all existing r products in attribute notation * 
***************************************************************************/

DROP TABLE IF EXISTS r_existing;
CREATE UNLOGGED TABLE r_existing AS
-- Marketed Product
SELECT c.concept_id, COALESCE(r3.value, 0) AS quant_value, COALESCE(r3.unit_id, 0) AS quant_unit_id, c.i_combo, c.d_combo, r1.df_id, COALESCE(r4.bn_id, 0) AS bn_id, COALESCE(r5.bs, 0) AS bs, r2.mf_id AS mf_id, 'Marketed Product' AS concept_class_id
FROM r_combo c
JOIN r_df r1 ON r1.concept_id = c.concept_id
JOIN r_mf r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_quant r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bn r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_bs r5 ON r5.concept_id = c.concept_id
WHERE c.d_combo <> ' '

UNION ALL

-- Quant Branded Box
SELECT c.concept_id, r1.value AS quant_value, r1.unit_id AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, r3.bn_id, r4.bs, 0 AS mf_id, 'Quant Branded Box' AS concept_class_id
FROM r_combo c
JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE c.d_combo <> ' '
	AND r5.concept_id IS NULL

UNION ALL

-- Quant Clinical Box
SELECT c.concept_id, r1.value AS quant_value, r1.unit_id AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, 0 AS bn_id, r4.bs, 0 AS mf_id, 'Quant Clinical Box' AS concept_class_id
FROM r_combo c
JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE c.d_combo <> ' '
	AND r3.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Branded Drug Box
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, r3.bn_id, r4.bs, 0 AS mf_id, 'Branded Drug Box' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r5.concept_id IS NULL

UNION ALL

-- Clinical Drug Box
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, 0 AS bn_id, r4.bs, 0 AS mf_id, 'Clinical Drug Box' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r3.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Quant Branded Drug
SELECT c.concept_id, r1.value AS quant_value, r1.unit_id AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, r3.bn_id, 0 AS bs, 0 AS mf_id, 'Quant Branded Drug' AS concept_class_id
FROM r_combo c
JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r4.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r5.concept_id IS NULL

UNION ALL

-- Quant Clinical Drug
SELECT c.concept_id, r1.value AS quant_value, r1.unit_id AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, 0 AS bn_id, 0 AS bs, 0 AS mf_id, 'Quant Clinical Drug' AS concept_class_id
FROM r_combo c
JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r3.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Branded Drug
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, r3.bn_id, 0 AS bs, 0 AS mf_id, 'Branded Drug' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Clinical Drug
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, r2.df_id, 0 AS bn_id, 0 AS bs, 0 AS mf_id, 'Clinical Drug' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r3.concept_id IS NULL
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Branded Drug Form
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, ' ' AS d_combo, r2.df_id, r3.bn_id, 0 AS bs, 0 AS mf_id, 'Branded Drug Form' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo = ' '
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Clinical Drug Form
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, ' ' AS d_combo, r2.df_id, 0 AS bn_id, 0 AS bs, 0 AS mf_id, 'Clinical Drug Form' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo = ' '
	AND r3.concept_id IS NULL
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL

UNION ALL

-- Branded Drug Component
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, 0 AS df_id, r3.bn_id, 0 AS bs, 0 AS mf_id, 'Branded Drug Comp' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
LEFT JOIN r_df r2 ON r2.concept_id = c.concept_id
JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r2.concept_id IS NULL
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL -- denominator_value is ignored

UNION ALL

-- Clinical Drug Component 
SELECT c.concept_id, 0 AS quant_value, 0 AS quant_unit_id, c.i_combo, c.d_combo, 0 AS df_id, 0 AS bn_id, 0 AS bs, 0 AS mf_id, 'Clinical Drug Comp' AS concept_class_id
FROM r_combo c
LEFT JOIN r_quant r1 ON r1.concept_id = c.concept_id
LEFT JOIN r_df r2 ON r2.concept_id = c.concept_id
LEFT JOIN r_bn r3 ON r3.concept_id = c.concept_id
LEFT JOIN r_bs r4 ON r4.concept_id = c.concept_id
LEFT JOIN r_mf r5 ON r5.concept_id = c.concept_id
WHERE r1.concept_id IS NULL
	AND c.d_combo <> ' '
	AND r2.concept_id IS NULL
	AND r3.concept_id IS NULL
	AND r4.concept_id IS NULL
	AND r5.concept_id IS NULL;

-- RxNorm has duplicates by attributes. Usually Ingredient and Precise Ingredient versions of the same drug. The Precise tends to be newer. This query picks the newest
DELETE
FROM r_existing r
WHERE EXISTS (
		SELECT 1
		FROM (
			SELECT r_int.ctid rowid,
				c.concept_name,
				FIRST_VALUE(c.concept_name) OVER (
					PARTITION BY r_int.quant_value,
					r_int.quant_unit_id,
					r_int.i_combo,
					r_int.d_combo,
					r_int.df_id,
					r_int.bn_id,
					r_int.bs,
					r_int.mf_id ORDER BY c.valid_start_date,
						c.concept_name DESC
					) AS newest
			FROM r_existing r_int
			JOIN concept c ON c.concept_id = r_int.concept_id
			) AS s0
		WHERE s0.concept_name <> s0.newest
			AND s0.rowid = r.ctid
		);

/************************************************************************************************
* 6. Create translation tables between q and r attributes with corridors, all starting with qr_ *
************************************************************************************************/

-- Create translation between q_uds and r_uds for everything in the 95% corridor and unit and ingredient closeness attributes
DROP TABLE IF EXISTS qr_uds;
CREATE UNLOGGED TABLE qr_uds AS
SELECT s0.q_ds,
	s0.r_ds,
	s0.u_prec,
	s0.i_prec,
	CASE 
		WHEN s0.div > 1
			THEN 1 / s0.div
		ELSE s0.div
		END AS div,
	s0.quant_unit,
	s0.quant_unit_id
FROM (
	-- Standard case where all units are identical after conversion, except %
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		CASE 
			WHEN q.amount_value <> 0
				AND r.amount_value <> 0
				THEN q.amount_value / r.amount_value
			WHEN q.numerator_value <> 0
				AND r.numerator_value <> 0
				THEN q.numerator_value / r.numerator_value -- the standard case
			ELSE 0
			END AS div,
		q.quant_unit,
		q.denominator_unit_concept_id AS quant_unit_id
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.amount_value * COALESCE(r2.conversion_factor, 1) AS amount_value,
			COALESCE(r2.concept_id_2, 0) AS amount_unit_concept_id,
			qu.numerator_value * COALESCE(r3.conversion_factor, 1) / COALESCE(r4.conversion_factor, 1) AS numerator_value,
			COALESCE(r3.concept_id_2, 0) AS numerator_unit_concept_id,
			COALESCE(r4.concept_id_2, 0) AS denominator_unit_concept_id,
			COALESCE(r2.precedence, (COALESCE(r3.precedence,0) + COALESCE(r4.precedence,0)) / 2, 100) AS u_prec, -- numerator unit precedence, or average of concentration precedences, or 100 (non-desirable conversion, missing conversion)
			qu.denominator_unit AS quant_unit -- when homeopathic potentiation the denominator is undefined
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		LEFT JOIN r_to_c r2 ON r2.concept_code_1 = qu.amount_unit -- amount units
		LEFT JOIN r_to_c r3 ON r3.concept_code_1 = qu.numerator_unit -- numerator units
		LEFT JOIN r_to_c r4 ON r4.concept_code_1 = qu.denominator_unit -- denominator units
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.amount_unit_concept_id = q.amount_unit_concept_id
		AND r.numerator_unit_concept_id = q.numerator_unit_concept_id
		AND r.denominator_unit_concept_id = q.denominator_unit_concept_id -- join q and r on the ingredient and all the units
	WHERE q.numerator_unit_concept_id <> 8554 -- %
	
	UNION
	
	-- % vs %
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		q.numerator_value / r.numerator_value AS div,
		NULL AS quant_unit,
		NULL AS quant_unit_id -- which is not defined, really, for situations like "10 mL oxygen 90%" to "10 mL oxygen 0.9 mL/mL", because the former has no denominator_unit. 
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.numerator_value * r2.conversion_factor AS numerator_value,
			8554 AS numerator_unit_concept_id,
			COALESCE(r2.precedence, 100) AS u_prec -- numerator unit precedence, or 100 (non-desirable conversion, missing conversion)
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		JOIN r_to_c r2 ON r2.concept_code_1 = qu.numerator_unit -- numerator unit conversion
		WHERE r2.concept_id_2 = 8554 -- %
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.numerator_unit_concept_id = 8554 -- %
	
	UNION
	
	-- % vs mg/mL
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		q.numerator_value / r.numerator_value * 10 AS div,
		NULL quant_unit,
		8587 AS quant_unit_id
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.numerator_value * COALESCE(r2.conversion_factor, 1) / COALESCE(r3.conversion_factor, 1) AS numerator_value,
			COALESCE(r2.concept_id_2, 0) AS numerator_unit_concept_id,
			COALESCE(r2.precedence, 100) AS u_prec -- numerator unit precedence, or 100 (non-desirable conversion, missing conversion)
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		LEFT JOIN r_to_c r2 ON r2.concept_code_1 = qu.numerator_unit -- numerator unit conversion
		LEFT JOIN r_to_c r3 ON r3.concept_code_1 = qu.denominator_unit -- denominator unit conversion
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.numerator_unit_concept_id = 8576
		AND r.denominator_unit_concept_id = 8587 -- mg/mL
	WHERE q.numerator_unit_concept_id = 8554 -- %
	
	UNION
	
	-- mg/mL vs %
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		q.numerator_value / r.numerator_value / 10 AS div,
		q.quant_unit,
		NULL AS quant_unit_id
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.numerator_value * COALESCE(r2.conversion_factor, 1) AS numerator_value,
			COALESCE(r2.concept_id_2, 0) AS numerator_unit_concept_id,
			COALESCE(r3.concept_id_2, 0) AS denominator_unit_concept_id,
			COALESCE(r2.precedence, 100) AS u_prec, -- numerator unit precedence, or 100 (non-desirable conversion, missing conversion)
			qu.denominator_unit AS quant_unit
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		LEFT JOIN r_to_c r2 ON r2.concept_code_1 = qu.numerator_unit -- numerator unit conversion
		LEFT JOIN r_to_c r3 ON r3.concept_code_1 = qu.denominator_unit -- denominator unit conversion
		WHERE qu.amount_unit = ' ' -- redundant with clause below that numerator/denominator=mg/mL, but faster to limit here
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.numerator_unit_concept_id = 8554 -- %
	WHERE q.numerator_unit_concept_id = 8576
		AND q.denominator_unit_concept_id = 8587 -- mg/mL
	
	UNION
	
	-- mg/mg etc. vs %
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		q.numerator_value / r.numerator_value * 100 AS div,
		q.quant_unit,
		NULL AS quant_unit_id
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.numerator_value,
			1 AS u_prec, -- doesn't matter which unit is used, they are used both in numerator and denominator
			qu.denominator_unit AS quant_unit
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		WHERE qu.amount_unit = ' '
			AND qu.numerator_unit = qu.denominator_unit -- mg/mg, mL/mL etc.
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.numerator_unit_concept_id = 8554 -- %
	
	UNION
	
	-- % vs mg/mg etc.
	SELECT q.ds_code AS q_ds,
		r.ds_code AS r_ds,
		q.u_prec,
		q.i_prec,
		q.numerator_value / r.numerator_value / 100 AS div,
		NULL AS quant_unit,
		r.denominator_unit_concept_id AS quant_unit_id
	FROM (
		-- q component with drug_strength in RxNorm speak (ids instead of codes)
		SELECT qu.ds_code,
			r1.concept_id_2 AS ingredient_concept_id,
			COALESCE(r1.precedence, 1) AS i_prec,
			qu.numerator_value * COALESCE(r2.conversion_factor, 1) AS numerator_value,
			COALESCE(r2.concept_id_2, 0) AS numerator_unit_concept_id,
			COALESCE(r3.concept_id_2, 0) AS denominator_unit_concept_id,
			COALESCE(r2.precedence, 100) AS u_prec -- numerator unit precedence, or 100 (non-desirable conversion, missing conversion)
		FROM q_uds qu
		JOIN r_to_c r1 ON r1.concept_code_1 = qu.ingredient_concept_code -- ingredient matching
		LEFT JOIN r_to_c r2 ON r2.concept_code_1 = qu.numerator_unit -- numerator unit conversion
		LEFT JOIN r_to_c r3 ON r3.concept_code_1 = qu.denominator_unit -- denominator unit conversion
		WHERE qu.amount_unit = ' '
		) q
	JOIN r_uds r ON r.ingredient_concept_id = q.ingredient_concept_id
		AND r.numerator_unit_concept_id = r.denominator_unit_concept_id
		AND r.amount_unit_concept_id = 0 -- mg/mg, mL/mL etc.
	WHERE q.numerator_unit_concept_id = 8554 -- %
	) AS s0
WHERE s0.div > 0.95
	AND 1 / s0.div > 0.95;-- find identicals only within a corridor of 95% deviation

-- Remove duplicate q-r_uds combos that can result from % (two units mapped into one) or due to duplicate unit mapping with different preferences
-- The former will happen likely, the latter only if the input files are corrupt
DELETE
FROM qr_uds
WHERE ctid NOT IN (
		SELECT FIRST_VALUE(ctid) OVER (
				PARTITION BY q_ds,
				r_ds ORDER BY u_prec,
					i_prec,
					div DESC
				)
		FROM qr_uds
		);

-- Create all possible translations for combos and their closeness attributes
-- This table still contains individual q_ds and r_ds enumerated, but aligned to each other, which is necessary for breaking up combos in x_pattern
DROP TABLE IF EXISTS qr_ds;
CREATE UNLOGGED TABLE qr_ds AS
	-- Create unique list of combo codes and ds components for both q and r
	-- Create q and the number of ds components
	WITH qc AS (
			SELECT *
			FROM (
				SELECT *,
					COUNT(*) OVER (PARTITION BY s0.d_combo) AS cnt
				FROM (
					SELECT DISTINCT qc.d_combo,
						qc.i_combo,
						qd.i_code,
						qd.ds_code,
						qd.quant_unit
					FROM q_combo qc
					JOIN q_ds qd ON qd.concept_code = qc.concept_code
					) s0
				) s1
			WHERE s1.cnt > 1
			),
		-- Same for r
		rc AS (
			SELECT *
			FROM (
				SELECT *,
					COUNT(*) OVER (PARTITION BY s0.d_combo) AS cnt
				FROM (
					SELECT DISTINCT rc.d_combo,
						rc.i_combo,
						rd.i_code,
						rd.ds_code,
						rd.quant_unit_id
					FROM r_combo rc
					JOIN r_ds rd ON rd.concept_id = rc.concept_id
					) s0
				) s1
			WHERE s1.cnt > 1
			),
		-- Create all combinations of combos that share at least one ds, and calculate their size of the combos
		q_to_r AS (
			SELECT qc.i_combo AS qi_combo, qc.d_combo AS qd_combo, qc.i_code AS q_i, q.q_ds, rc.i_combo AS ri_combo, rc.d_combo AS rd_combo, rc.i_code AS r_i, q.r_ds, q.u_prec, q.i_prec, q.div, qc.cnt, q.quant_unit, q.quant_unit_id
			FROM qr_uds q
			JOIN qc ON qc.ds_code = q.q_ds
			JOIN rc ON rc.ds_code = q.r_ds
				AND qc.cnt = rc.cnt
			)
-- Now filter those where the size of the q and r combos (already the same) is the same as the number of qr_uds matches between the combos
SELECT qr.qi_combo, qr.ri_combo, s0.qd_combo, s0.rd_combo, qr.q_i, qr.q_ds, qr.r_i, qr.r_ds, qr.u_prec, qr.i_prec, qr.div, qr.quant_unit, qr.quant_unit_id
FROM (
	SELECT qr_int.qd_combo, qr_int.rd_combo, COUNT(*) AS cnt
	FROM q_to_r qr_int
	GROUP BY qr_int.qd_combo, qr_int.rd_combo
	) AS s0
JOIN q_to_r qr ON qr.qd_combo = s0.qd_combo
	AND qr.rd_combo = s0.rd_combo
	AND qr.cnt = s0.cnt;-- makes sure that the qd-rd combos have the same ds count as the individual ones

-- Now create unique combos, shedding the q_ds and r_ds enumeration
DROP TABLE IF EXISTS qr_d_combo;
CREATE UNLOGGED TABLE qr_d_combo AS
SELECT qi_combo,
	ri_combo,
	qd_combo,
	rd_combo,
	AVG(u_prec) AS u_prec,
	AVG(i_prec) AS i_prec,
	AVG(div) AS div, -- for successful matches, calculate aggregate u_prec, i_prec and div
	MAX(quant_unit) AS quant_unit,
	MAX(quant_unit_id) AS quant_unit_id
FROM qr_ds
GROUP BY qi_combo,
	ri_combo,
	qd_combo,
	rd_combo
HAVING COUNT(DISTINCT quant_unit_id) = 1;-- count the number of different quant_unit_ids. Discard if more than one (non-matching denominators)

-- Add singleton combos from qr_uds. Some of them will be necessary as they don't exist as singletons in q, but x_i_combo will need them for translating ingredient combos in Forms
INSERT INTO qr_d_combo
SELECT DISTINCT qu.ingredient_concept_code AS qi_combo,
	ru.i_code AS ri_combo,
	qu.ds_code AS qd_combo,
	ru.ds_code AS rd_combo,
	qru.u_prec,
	qru.i_prec,
	qru.div,
	qru.quant_unit,
	qru.quant_unit_id
FROM qr_uds qru
JOIN q_uds qu ON qu.ds_code = qru.q_ds
JOIN r_uds ru ON ru.ds_code = qru.r_ds;

-- Same for ingredient combinations only (used for Drug Forms)
-- First, create table with q_i and r_i listed
DROP TABLE IF EXISTS qr_i;
CREATE UNLOGGED TABLE qr_i AS -- qr_ing is for single ingredients
	WITH q AS (
			SELECT DISTINCT qc.i_combo,
				qi.i_code
			FROM q_combo qc
			JOIN q_ing qi ON qi.concept_code = qc.concept_code
			),
		r AS (
			SELECT DISTINCT rc.i_combo,
				ri.i_code
			FROM r_combo rc
			JOIN r_ing ri ON ri.concept_id = rc.concept_id
			),
		-- Create all combinations of combos that share at least one ing, and calculate their size of the combos
		q_to_r_1 AS (
			SELECT qc.i_combo AS q_combo,
				c.q_ing, --rc.i_combo as r_combo,   
				c.r_ing,
				c.i_prec,
				qc.cnt
			FROM (
				-- create a combination of all possible ingredient to ingredient maps
				SELECT DISTINCT qi.i_code AS q_ing,
					rtc.precedence AS i_prec,
					ri.i_code AS r_ing
				FROM q_ing qi
				JOIN r_to_c rtc ON qi.i_code = rtc.concept_code_1
				JOIN (
					SELECT DISTINCT i_id,
						i_code
					FROM r_ing
					) AS ri ON ri.i_id = rtc.concept_id_2
				) c
			-- Create q and the number of ds components
			JOIN (
				SELECT i_combo,
					i_code,
					COUNT(*) OVER (PARTITION BY i_combo) AS cnt
				FROM q
				) qc ON qc.i_code = c.q_ing
			),
		q_to_r_2 AS (
			SELECT qtr.q_combo,
				qtr.q_ing,
				rc.i_combo AS r_combo,
				qtr.r_ing,
				qtr.i_prec,
				qtr.cnt
			FROM q_to_r_1 qtr
			-- Create r and the number of ds components 
			JOIN (
				SELECT i_combo,
					i_code,
					COUNT(*) OVER (PARTITION BY i_combo) AS cnt
				FROM r
				) rc ON rc.i_code = qtr.r_ing
				AND rc.cnt = qtr.cnt -- join q to r through q_to_r_uds, and also the size of the combos
			)
-- Now filter those where the size of the q and r combos (already the same) is the same as the number of q_to_r_uds matches between the combos
SELECT s1.q_ing AS q_i,
	s1.q_combo AS qi_combo,
	s1.r_ing AS r_i,
	s1.r_combo AS ri_combo,
	s1.i_prec
FROM (
	SELECT *
	FROM (
		SELECT q_ing,
			q_combo,
			r_ing,
			r_combo,
			i_prec,
			cnt,
			COUNT(*) OVER (
				PARTITION BY q_combo,
				r_combo
				) AS cnt2
		FROM q_to_r_2
		) AS s0
	WHERE s0.cnt = s0.cnt2
	) AS s1;

-- Second, group and average the prec
DROP TABLE IF EXISTS qr_i_combo;
CREATE UNLOGGED TABLE qr_i_combo AS
SELECT qi_combo,
	ri_combo,
	AVG(i_prec) AS i_prec -- for successful matches, calculate aggregate i_prec
FROM qr_i
GROUP BY qi_combo,
	ri_combo;

-- Create translations between quants. Value and unit have to work in tandem
DROP TABLE IF EXISTS qr_quant;
CREATE UNLOGGED TABLE qr_quant AS
	WITH s0 AS (
			SELECT q.value AS q_value,
				q.unit AS quant_unit,
				r.value AS r_value,
				r.unit_id AS quant_unit_id,
				rtc.precedence AS prec,
				q.value * COALESCE(rtc.conversion_factor, 1) / r.value AS q_div
			FROM (
				SELECT DISTINCT value,
					unit
				FROM q_quant
				) q
			JOIN r_to_c rtc ON rtc.concept_code_1 = q.unit
			JOIN (
				SELECT DISTINCT value,
					unit_id
				FROM r_quant
				) r ON r.unit_id = rtc.concept_id_2
			),
		s1 AS (
			SELECT q_value,
				quant_unit,
				min(abs(q_div - 1)) AS div_precis
			FROM s0
			WHERE ROUND(q_div * 50) = 50 -- making it a 2% corridor
			GROUP BY q_value,
				quant_unit
			)
SELECT s0.*
FROM s0
JOIN s1 ON s0.q_value = s1.q_value
	AND s0.quant_unit = s1.quant_unit
	AND abs(s0.q_div - 1) = s1.div_precis;--most precise available

-- Translation between individual Ingredients
DROP TABLE IF EXISTS qr_ing;
CREATE UNLOGGED TABLE qr_ing AS
SELECT q.i_code AS qi_code,
	r.i_code AS ri_code,
	rtc.precedence AS prec
FROM (
	SELECT DISTINCT i_code
	FROM q_ing
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.i_code
JOIN (
	SELECT DISTINCT i_id,
		i_code
	FROM r_ing
	) r ON r.i_id = rtc.concept_id_2;

-- Translation between Dose Forms
DROP TABLE IF EXISTS qr_df;
CREATE UNLOGGED TABLE qr_df AS
SELECT q.df_code,
	r.df_id,
	rtc.precedence AS df_prec
FROM (
	SELECT DISTINCT df_code
	FROM q_df
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.df_code
JOIN (
	SELECT DISTINCT df_id
	FROM r_df
	) r ON r.df_id = rtc.concept_id_2;

-- Add those that are not used in r, but exist and are used in q
INSERT INTO qr_df
SELECT DISTINCT q.df_code,
	FIRST_VALUE(rtc.concept_id_2) OVER (
		PARTITION BY q.df_code ORDER BY COALESCE(rtc.precedence, 1)
		) AS df_id,
	1 AS df_prec
FROM (
	SELECT DISTINCT df_code
	FROM q_df
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.df_code
	AND NOT EXISTS (
		SELECT 1
		FROM qr_df q_int
		WHERE q_int.df_code = q.df_code
		);

-- Translation between Dose Forms
DROP TABLE IF EXISTS qr_bn;
CREATE UNLOGGED TABLE qr_bn AS
SELECT q.bn_code,
	r.bn_id,
	rtc.precedence AS bn_prec
FROM (
	-- limit to brand names in q
	SELECT DISTINCT bn_code
	FROM q_bn
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.bn_code
JOIN (
	-- limit to brand names in r
	SELECT DISTINCT bn_id
	FROM r_bn
	) r ON r.bn_id = rtc.concept_id_2;

-- Add those that are not used in r, but exist and are used in q
INSERT INTO qr_bn
SELECT DISTINCT q.bn_code,
	FIRST_VALUE(rtc.concept_id_2) OVER (
		PARTITION BY q.bn_code ORDER BY COALESCE(rtc.precedence, 1)
		) AS bn_id,
	1 AS bn_prec
FROM (
	SELECT DISTINCT bn_code
	FROM q_bn
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.bn_code
	AND NOT EXISTS (
		SELECT 1
		FROM qr_bn q_int
		WHERE q_int.bn_code = q.bn_code
		);

-- Translation between Dose Forms
DROP TABLE IF EXISTS qr_mf;
CREATE UNLOGGED TABLE qr_mf AS
SELECT q.mf_code,
	r.mf_id,
	rtc.precedence AS mf_prec
FROM (
	-- limit to supplier in q
	SELECT DISTINCT mf_code
	FROM q_mf
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.mf_code
JOIN (
	-- limit to supplier in r
	SELECT DISTINCT mf_id
	FROM r_mf
	) r ON r.mf_id = rtc.concept_id_2;

-- Add those that are not used in r, but exist and are used in q
INSERT INTO qr_mf
SELECT DISTINCT q.mf_code,
	FIRST_VALUE(rtc.concept_id_2) OVER (
		PARTITION BY q.mf_code ORDER BY COALESCE(rtc.precedence, 1)
		) AS mf_id,
	1 AS mf_prec
FROM (
	SELECT DISTINCT mf_code
	FROM q_mf
	) q
JOIN r_to_c rtc ON rtc.concept_code_1 = q.mf_code
	AND NOT EXISTS (
		SELECT 1
		FROM qr_mf q_int
		WHERE q_int.mf_code = q.mf_code
		);

-- No need for translating box sizes

/*************************************************************************
* 7. Compare new drug vocabulary q to existing one r and create patterns *
*************************************************************************/
-- Strategy: Find the optimal match for a varying number of existing component matches: d_combo/i_combo, df, bn and mf
-- Don't worry about duplication or conflicts. The actual matching of complete q to r will go top down and pull in incomplete patterns if they haven't been found yet

-- Create translations of units. Do it now, because it is needed for x_pattern to decide precedence
DROP TABLE IF EXISTS x_unit;
CREATE UNLOGGED TABLE x_unit AS
SELECT rtc.concept_code_1 AS unit_code,
	rtc.concept_id_2 AS unit_id,
	rtc.precedence,
	rtc.conversion_factor
FROM r_to_c rtc
WHERE EXISTS (
		SELECT 1
		FROM drug_concept_stage dcs_int
		WHERE dcs_int.concept_code = rtc.concept_code_1
			AND dcs_int.concept_class_id = 'Unit'
			AND dcs_int.vocabulary_id = rtc.vocabulary_id_1
		);

-- Prep dose form groups (with some additions for RxNorm Extension) as a way to stratify drug_strength translation within such group
DROP TABLE IF EXISTS dfg;
CREATE UNLOGGED TABLE dfg AS
SELECT DISTINCT c.concept_id AS df_id, COALESCE(m.concept_id_2, c.concept_id) AS dfg_id -- not all of them have a DFG, they stand for themselves
FROM concept c
LEFT JOIN (
	SELECT cr.concept_id_1, cr.concept_id_2, NULL
	FROM concept_relationship cr
	JOIN concept c_int ON c_int.concept_id = cr.concept_id_2
		AND c_int.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND c_int.concept_class_id = 'Dose Form Group'
	
	UNION ALL
	
	VALUES (43126086, 36217219, 'Drug Implant Product'), -- Intrauterine System
		(21014175, 36217219, 'Drug Implant Product'), -- Intrauterine device
		(43563502, 36217218, 'Ophthalmic Product'), -- Intravitreal Applicator
		(43126087, 36217206, 'Topical Product'), -- Medicated Nail Polish
		(21014177, 36217206, 'Topical Product'), -- Medicated nail lacquer
		(43563498, 36217213, 'Nasal Product'), -- Nasal Pin
		(19129401, 36217206, 'Topical Product'), -- Ointment
		(21014169, 36217206, 'Topical Product'), -- Paint
		(21014176, 36217206, 'Topical Product'), -- Poultice
		(43563504, 36217215, 'Dental Product'), --Dental Pin
		(21014171, 36217215, 'Dental Product'), -- Dental insert
		(19082079, -1, 'Made-up extended release oral produt'), -- Extended Release Oral Tablet
		(19082077, -1, 'Made-up extended release oral produt'), -- Extended Release Oral Capsule
		(19001949, -1, 'Made-up extended release oral produt'), -- Delayed Release Oral Tablet
		(19082255, -1, 'Made-up extended release oral produt'), -- Delayed Release Oral Capsule
		(19082072, 36244042, 'Transdermal System'), -- 72 Hour Transdermal Patch
		(19082073, 36244042, 'Transdermal System'), -- Biweekly Transdermal Patch
		(19082252, 36244042, 'Transdermal System'), -- Weekly Transdermal Patch
		(19082229, 36244042, 'Transdermal System'), -- Transdermal System
		(19082049, 36244042, 'Transdermal System'), -- 16 Hour Transdermal Patch
		(19082071, 36244042, 'Transdermal System'), -- 24 Hour Transdermal Patch
		(42629089, 36244042, 'Transdermal System'), -- Medicated Patch
		(19130307, 36244042, 'Transdermal System'), -- Medicated Pad
		(19130329, 36244042, 'Transdermal System'), -- Medicated Tape
		(19082701, 36244042, 'Transdermal System'), -- Patch
		(46275062, -2, 'Made-up device injector'), -- Jet Injector
		(46234468, -2, 'Made-up device injector'), -- Cartridge
		(46234467, -2, 'Made-up device injector'), -- Pen Injector
		(46234466, -2, 'Made-up device injector'), -- Auto-Injector 
		(19000942, -3, 'Suppository Product'), -- Suppository
		(19082200, -3, 'Suppository Product') -- Rectal Suppository
	) m ON m.concept_id_1 = c.concept_id
WHERE c.vocabulary_id IN (
		'RxNorm',
		'RxNorm Extension'
		)
	AND c.concept_class_id = 'Dose Form'
	AND c.invalid_reason IS NULL;

-- Delete Dose Form Groups that are too broad
DELETE
FROM dfg
WHERE dfg_id = 36217214;-- Oral Product

-- Take out Dose Forms that make DFGs too broad
DELETE
FROM dfg
WHERE dfg_id = 36217210 -- injection 
	AND df_id IN (
		46275062, -- Jet Injector
		46234468, -- Cartridge
		46234467, -- Pen Injector
		46234466 -- Auto-Injector
		);

DELETE
FROM dfg
WHERE dfg_id = 36217206 -- Topical Product
	AND df_id IN (
		19082072, -- 72 Hour Transdermal Patch
		19082073, -- Biweekly Transdermal Patch
		19082252, -- Weekly Transdermal Patch
		19082229, -- Transdermal System
		19082049, -- 16 Hour Transdermal Patch
		19082071, -- 24 Hour Transdermal Patch
		42629089, -- Medicated Patch
		19130307, -- Medicated Pad
		19130329, -- Medicated Tape
		19082701, -- Patch
		35604394, -- Topical Liquefied Gas
		19082281 -- Powder Spray
		);

DELETE
FROM dfg
WHERE dfg_id = 36217216 -- Pill
	AND df_id IN (
		19082079, -- Extended Release Oral Tablet
		19082077, -- Extended Release Oral Capsule
		19001949, -- Delayed Release Oral Tablet
		19082255 -- Delayed Release Oral Capsule
		);

DELETE
FROM dfg
WHERE dfg_id = 36217209 -- Vaginal Product
	AND df_id IN (
		19010962, -- Vaginal Tablet
		19082230, -- Vaginal Powder
		40167393, -- Vaginal Ring
		19093368 -- Vaginal Suppository
		);

DELETE
FROM dfg
WHERE dfg_id = 36217211 -- Rectal Product 
	AND df_id IN (
		19082198, -- Rectal Powder
		19082199, -- Rectal Spray
		19082627 -- Enema
		);

DELETE
FROM dfg
WHERE dfg_id = 36217213 -- Nasal Product
	AND df_id IN (
		19082162, -- Nasal Inhalant
		19126919, -- Nasal Inhaler
		19011167 -- Nasal Spray
		);

-- for the subsequent build
DROP TABLE IF EXISTS x_pattern;
CREATE UNLOGGED TABLE x_pattern (
	qi_combo VARCHAR(1000),
	ri_combo VARCHAR(1000),
	qd_combo VARCHAR(1000),
	rd_combo VARCHAR(1000),
	df_code VARCHAR(50),
	df_id int4,
	dfg_id int4,
	bn_code VARCHAR(50),
	bn_id int4,
	mf_code VARCHAR(50),
	mf_id int4,
	quant_unit VARCHAR(50),
	quant_unit_id int4,
	prec int4
	);

-- 1. and 2. Match all 4: d_combo, df, bn and mf have to match - Marketed Products. Marketed Products without bn is prec=5 and 6
INSERT INTO x_pattern
SELECT q.*,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 1 -- solid drug
		WHEN xu.precedence = 1
			THEN 1 -- quant_unit and quant_unit_id match according to prec
		ELSE 2
		END AS prec
FROM (
	SELECT DISTINCT q_int.qi_combo,
		FIRST_VALUE(q_int.ri_combo) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS ri_combo,
		q_int.qd_combo,
		FIRST_VALUE(q_int.rd_combo) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS rd_combo,
		q_int.df_code,
		FIRST_VALUE(q_int.df_id) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS df_id,
		FIRST_VALUE(q_int.dfg_id) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS dfg_id,
		q_int.bn_code,
		FIRST_VALUE(q_int.bn_id) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS bn_id,
		q_int.mf_code,
		FIRST_VALUE(q_int.mf_id) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS mf_id,
		FIRST_VALUE(q_int.quant_unit) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS quant_unit,
		FIRST_VALUE(q_int.quant_unit_id) OVER (
			PARTITION BY q_int.qd_combo,
			q_int.df_code,
			q_int.bn_code,
			q_int.mf_code ORDER BY q_int.mf_prec,
				q_int.bn_prec,
				q_int.df_prec,
				q_int.div DESC,
				q_int.i_prec,
				q_int.u_prec
			) AS quant_unit_id
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo, c.ri_combo, eq.d_combo AS qd_combo, c.rd_combo, c.u_prec, c.i_prec, c.div, eq.df_code, df.df_id, df.df_prec, d.dfg_id, eq.bn_code, bn.bn_id, bn.bn_prec, eq.mf_code, mf.mf_id, mf.mf_prec, c.quant_unit, c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential df_ids
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		LEFT JOIN qr_bn bn ON bn.bn_code = eq.bn_code -- get potential brand names, may not exist in Marketed Products
		JOIN qr_mf mf ON mf.mf_code = eq.mf_code -- get potential manufacturers
		) q_int
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q_int.rd_combo
				AND r_e.df_id = q_int.df_id
				AND r_e.bn_id = q_int.bn_id
				AND r_e.mf_id = q_int.mf_id
			)
	) q
LEFT JOIN x_unit xu ON xu.unit_code = q.quant_unit
	AND xu.unit_id = q.quant_unit_id;

-- Break up multi-combos and write back leaving all other patterns unchanged
-- This is necessary for Clinical Drug Comps where comobos only exist in multi-versions in both q and r
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q.q_ds AS qd_combo, q.r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 3-6. Match d_combo, df, bn, but not mf - Branded Drug, quantified and boxed
INSERT INTO x_pattern
-- take out null values from union for performance
SELECT s0.qi_combo,
	s0.ri_combo,
	s0.qd_combo,
	s0.rd_combo,
	s0.df_code,
	s0.df_id,
	s0.dfg_id,
	s0.bn_code,
	s0.bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	s0.quant_unit,
	s0.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 3 + s0.new_rec -- solid drug
		WHEN xu.precedence = 1
			THEN 3 + s0.new_rec -- quant_unit and quant_unit_id match according to prec
		ELSE 5 + s0.new_rec
		END AS prec -- 5 if quant doesn't match
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		q.df_code,
		FIRST_VALUE(q.df_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS df_id,
		FIRST_VALUE(q.dfg_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS dfg_id,
		q.bn_code,
		FIRST_VALUE(q.bn_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS bn_id,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		FIRST_VALUE(q.quant_unit_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit_id,
		1 AS new_rec -- prefer those that are handed down
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo, c.ri_combo, eq.d_combo AS qd_combo, c.rd_combo, c.u_prec, c.i_prec, c.div, eq.df_code, df.df_id, df.df_prec, d.dfg_id, eq.bn_code, bn.bn_id, bn.bn_prec, c.quant_unit, c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential df_ids
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		JOIN qr_bn bn ON bn.bn_code = eq.bn_code -- get potential brand names, may not exist in Marketed Products
		WHERE eq.mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form and brand name
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q.rd_combo
				AND r_e.df_id = q.df_id
				AND r_e.bn_id = q.bn_id
			)
	
	UNION ALL -- get existing patterns
	
	SELECT DISTINCT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, quant_unit, quant_unit_id, 0 AS new_rec
	FROM x_pattern
	WHERE df_code IS NOT NULL
		AND bn_code IS NOT NULL
	) AS s0
LEFT JOIN x_unit xu ON xu.unit_code = s0.quant_unit
	AND xu.unit_id = s0.quant_unit_id;

-- Break up multi-combos
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q_ds AS qd_combo, r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec -- as already exists, but to distinguish from original
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 7-10. Match d_combo, df, mf, but not bn - Marketed Products without Brand, quantified or boxed
INSERT INTO x_pattern
SELECT s0.qi_combo,
	s0.ri_combo,
	s0.qd_combo,
	s0.rd_combo,
	s0.df_code,
	s0.df_id,
	s0.dfg_id,
	NULL AS bn_code,
	NULL AS bn_id,
	s0.mf_code,
	s0.mf_id,
	s0.quant_unit,
	s0.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 7 + s0.new_rec -- solid drug
		WHEN xu.precedence = 1
			THEN 7 + s0.new_rec -- quant_unit and quant_unit_id match according to prec
		ELSE 9 + s0.new_rec
		END AS prec -- if quant doesn't match
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		q.df_code,
		FIRST_VALUE(q.df_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS df_id,
		FIRST_VALUE(q.dfg_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS dfg_id,
		q.mf_code,
		FIRST_VALUE(q.mf_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS mf_id,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		FIRST_VALUE(q.quant_unit_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code,
			q.mf_code ORDER BY q.mf_prec,
				q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo,
			c.ri_combo,
			eq.d_combo AS qd_combo,
			c.rd_combo,
			c.u_prec,
			c.i_prec,
			c.div,
			eq.df_code,
			df.df_id,
			df.df_prec,
			d.dfg_id,
			eq.mf_code,
			mf.mf_id,
			mf.mf_prec,
			c.quant_unit,
			c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential df_ids  join qr_bn bn on bn.bn_code=eq.bn_code -- get potential brand names, may not exist in Marketed Products
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		JOIN qr_mf mf ON mf.mf_code = eq.mf_code -- get potential manufacturers
		WHERE bn_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q.rd_combo
				AND r_e.df_id = q.df_id
				AND r_e.mf_id = q.mf_id
			)
	
	UNION ALL -- get existing pattern
	
	SELECT DISTINCT qi_combo,
		ri_combo,
		qd_combo,
		rd_combo,
		df_code,
		df_id,
		dfg_id,
		mf_code,
		mf_id,
		quant_unit,
		quant_unit_id,
		0 AS new_rec
	FROM x_pattern
	WHERE df_code IS NOT NULL
		AND mf_code IS NOT NULL
	) AS s0
LEFT JOIN x_unit xu ON xu.unit_code = s0.quant_unit
	AND xu.unit_id = s0.quant_unit_id;

-- Break up multi-combos
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q_ds AS qd_combo, r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec -- as already exists
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 11-14. Match d_combo, df, but not bn, mf - Clinical Drug, quantified or boxed
INSERT INTO x_pattern
SELECT s0.qi_combo,
	s0.ri_combo,
	s0.qd_combo,
	s0.rd_combo,
	s0.df_code,
	s0.df_id,
	s0.dfg_id,
	NULL AS bn_code,
	NULL AS bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	s0.quant_unit,
	s0.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 11 + s0.new_rec -- solid drug
		WHEN xu.precedence = 1
			THEN 11 + s0.new_rec -- quant_unit and quant_unit_id match according to prec
		ELSE 13 + s0.new_rec
		END AS prec -- if quant doesn't match
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		q.df_code,
		FIRST_VALUE(q.df_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS df_id,
		FIRST_VALUE(q.dfg_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS dfg_id,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		FIRST_VALUE(q.quant_unit_id) OVER (
			PARTITION BY q.qd_combo,
			q.df_code ORDER BY q.df_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo,
			c.ri_combo,
			eq.d_combo AS qd_combo,
			c.rd_combo,
			c.u_prec,
			c.i_prec,
			c.div,
			eq.df_code,
			df.df_id,
			df.df_prec,
			d.dfg_id,
			c.quant_unit,
			c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential df_ids
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		WHERE bn_code = ' '
			AND mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q.rd_combo
				AND r_e.df_id = q.df_id
			)
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, quant_unit, quant_unit_id, 0 AS new_rec
	FROM x_pattern
	WHERE df_code IS NOT NULL
	) AS s0
LEFT JOIN x_unit xu ON xu.unit_code = s0.quant_unit
	AND xu.unit_id = s0.quant_unit_id;

-- Break up multi-combos
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q_ds AS qd_combo, r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec -- as already exists
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 15-18. Match d_combo, bn, but not df, mf - Branded Component
INSERT INTO x_pattern
SELECT s0.qi_combo,
	s0.ri_combo,
	s0.qd_combo,
	s0.rd_combo,
	NULL AS df_code,
	NULL AS df_id,
	NULL AS dfg_id,
	s0.bn_code,
	s0.bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	s0.quant_unit,
	s0.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 15 + s0.new_rec -- solid drug
		WHEN xu.precedence = 1
			THEN 15 + s0.new_rec -- quant_unit and quant_unit_id match according to prec
		ELSE 17 + s0.new_rec
		END AS prec
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo,
			q.bn_code ORDER BY q.bn_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo,
			q.bn_code ORDER BY q.bn_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		q.bn_code,
		FIRST_VALUE(q.bn_id) OVER (
			PARTITION BY q.qd_combo,
			q.bn_code ORDER BY q.bn_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS bn_id,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo,
			q.bn_code ORDER BY q.bn_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		FIRST_VALUE(q.quant_unit_id) OVER (
			PARTITION BY q.qd_combo,
			q.bn_code ORDER BY q.bn_prec,
				q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo,
			c.ri_combo,
			eq.d_combo AS qd_combo,
			c.rd_combo,
			c.u_prec,
			c.i_prec,
			c.div,
			eq.bn_code,
			bn.bn_id,
			bn.bn_prec,
			c.quant_unit,
			c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		JOIN qr_bn bn ON bn.bn_code = eq.bn_code -- get potential brand names, may not exist in Marketed Products
		WHERE df_code = ' '
			AND mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q.rd_combo
				AND r_e.bn_id = q.bn_id
			)
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, qd_combo, rd_combo, bn_code, bn_id, quant_unit, quant_unit_id, 0 AS new_rec
	FROM x_pattern
	WHERE bn_code IS NOT NULL
	) AS s0
LEFT JOIN x_unit xu ON xu.unit_code = s0.quant_unit
	AND xu.unit_id = s0.quant_unit_id;

-- Break up multi-combos
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q_ds AS qd_combo, r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec -- as already exists
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 19-22. Match d_combo, but not df, bn, mf - Clinical Component
INSERT INTO x_pattern
SELECT s0.qi_combo,
	s0.ri_combo,
	s0.qd_combo,
	s0.rd_combo,
	NULL AS df_code,
	NULL AS df_id,
	NULL AS dfg_id,
	NULL AS bn_code,
	NULL AS bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	s0.quant_unit,
	s0.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 19 + s0.new_rec -- solid drug
		WHEN xu.precedence = 1
			THEN 19 + s0.new_rec -- quant_unit and quant_unit_id match according to prec
		ELSE 21 + s0.new_rec
		END AS prec
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		FIRST_VALUE(q.quant_unit_id) OVER (
			PARTITION BY q.qd_combo ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo, c.ri_combo, eq.d_combo AS qd_combo, c.rd_combo, c.u_prec, c.i_prec, c.div, c.quant_unit, c.quant_unit_id -- unit combination, needed to translate quant correctly
		FROM q_existing eq
		JOIN qr_d_combo c ON c.qd_combo = eq.d_combo -- get all potential rd_combos
		WHERE df_code = ' '
			AND bn_code = ' '
			AND mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.d_combo = q.rd_combo
			)
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, qd_combo, rd_combo, quant_unit, quant_unit_id, 0 AS new_rec
	FROM x_pattern
	) AS s0
LEFT JOIN x_unit xu ON xu.unit_code = s0.quant_unit
	AND xu.unit_id = s0.quant_unit_id;

-- Break up multi-combos and write back leaving all other patterns unchanged
INSERT INTO x_pattern
SELECT DISTINCT q.q_i AS qi_combo, q.r_i AS ri_combo, q_ds AS qd_combo, r_ds AS rd_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.mf_code, x.mf_id, x.quant_unit, x.quant_unit_id, x.prec -- as already exists
FROM x_pattern x
JOIN qr_ds q ON q.qd_combo = x.qd_combo
	AND q.rd_combo = x.rd_combo

EXCEPT

SELECT qi_combo, ri_combo, qd_combo, rd_combo, df_code, df_id, dfg_id, bn_code, bn_id, mf_code, mf_id, quant_unit, quant_unit_id, prec
FROM x_pattern;

-- 23-24. Match i_combo, df, bn but no mf - Branded Forms
INSERT INTO x_pattern
SELECT qi_combo,
	ri_combo,
	NULL AS qd_combo,
	NULL AS rd_combo,
	df_code,
	df_id,
	dfg_id,
	bn_code,
	bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	NULL AS quant_unit,
	NULL AS quant_unit_id,
	23 + new_rec AS prec
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qi_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.i_prec
			) AS ri_combo,
		q.df_code,
		FIRST_VALUE(q.df_id) OVER (
			PARTITION BY q.qi_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.i_prec
			) AS df_id,
		FIRST_VALUE(q.dfg_id) OVER (
			PARTITION BY q.qi_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.i_prec
			) AS dfg_id,
		q.bn_code,
		FIRST_VALUE(q.bn_id) OVER (
			PARTITION BY q.qi_combo,
			q.df_code,
			q.bn_code ORDER BY q.bn_prec,
				q.df_prec,
				q.i_prec
			) AS bn_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo, c.ri_combo, c.i_prec, eq.df_code, df.df_id, df.df_prec, d.dfg_id, eq.bn_code, bn.bn_id, bn.bn_prec
		FROM q_existing eq
		JOIN qr_i_combo c ON c.qi_combo = eq.i_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential brand names, may not exist in Marketed Products
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		JOIN qr_bn bn ON bn.bn_code = eq.bn_code -- get potential brand names, may not exist in Marketed Products
		WHERE d_combo = ' '
			AND mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.i_combo = q.ri_combo
				AND r_e.df_id = q.df_id
				AND r_e.bn_id = q.bn_id
			)
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, df_code, df_id, dfg_id, bn_code, bn_id, 0 AS new_rec
	FROM x_pattern
	WHERE df_code IS NOT NULL
		AND bn_code IS NOT NULL
	) AS s0;

-- Break up mulit-i_combos and write back leaving all other patterns unchanged
INSERT INTO x_pattern
SELECT s0.qi_combo, s0.ri_combo, NULL AS qd_combo, NULL AS rd_combo, s0.df_code, s0.df_id, s0.dfg_id, s0.bn_code, s0.bn_id, NULL AS mf_code, NULL AS mf_id, NULL AS quant_unit, NULL AS quant_unit_id, s0.prec
FROM (
	SELECT q.q_i AS qi_combo, q.r_i AS ri_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.prec
	FROM x_pattern x
	JOIN qr_i q ON q.qi_combo = x.qi_combo
		AND q.ri_combo = x.ri_combo -- get right component in a combination aligned
	WHERE x.qd_combo IS NULL -- only Form patterns
		AND x.qi_combo LIKE '%-%' -- only combinations, otherwise nothing to break up
	
	EXCEPT
	
	SELECT qi_combo, ri_combo, df_code, df_id, dfg_id, bn_code, bn_id, prec
	FROM x_pattern
	) AS s0;

-- 25-26. Match i_combo, df but not bn, mf - Clinical Forms
INSERT INTO x_pattern
SELECT s0.qi_combo,
	s0.ri_combo,
	NULL AS qd_combo,
	NULL AS rd_combo,
	s0.df_code,
	s0.df_id,
	s0.dfg_id,
	NULL AS bn_code,
	NULL AS bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	NULL AS quant_unit,
	NULL AS quant_unit_id,
	25 + s0.new_rec AS prec
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qi_combo,
			q.df_code ORDER BY q.df_prec,
				q.i_prec
			) AS ri_combo,
		q.df_code,
		FIRST_VALUE(q.df_id) OVER (
			PARTITION BY q.qi_combo,
			q.df_code ORDER BY q.df_prec,
				q.i_prec
			) AS df_id,
		FIRST_VALUE(q.dfg_id) OVER (
			PARTITION BY q.qi_combo,
			q.df_code ORDER BY q.df_prec,
				q.i_prec
			) AS dfg_id,
		1 AS new_rec
	FROM (
		-- create q_existing with all attributes extended to their r-corridors
		SELECT eq.i_combo AS qi_combo,
			c.ri_combo,
			c.i_prec,
			eq.df_code,
			df.df_id,
			df.df_prec,
			d.dfg_id
		FROM q_existing eq
		JOIN qr_i_combo c ON c.qi_combo = eq.i_combo -- get all potential rd_combos
		JOIN qr_df df ON df.df_code = eq.df_code -- get potential brand names, may not exist in Marketed Products
		JOIN dfg d ON d.df_id = df.df_id -- get larger df group
		WHERE d_combo = ' '
			AND bn_code = ' '
			AND mf_code = ' '
		) q
	-- pick those rd_combos that actually exist in combination with dose form, brand name and manufacturer
	WHERE EXISTS (
			SELECT 1
			FROM r_existing r_e
			WHERE r_e.i_combo = q.ri_combo
				AND r_e.df_id = q.df_id
			)
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, df_code, df_id, dfg_id, 0 AS new_rec
	FROM x_pattern
	WHERE df_code IS NOT NULL
	) AS s0;

-- Break up mulit-i_combos and write back leaving all other patterns unchanged
INSERT INTO x_pattern
SELECT s0.qi_combo, s0.ri_combo, NULL AS qd_combo, NULL AS rd_combo, s0.df_code, s0.df_id, s0.dfg_id, s0.bn_code, s0.bn_id, NULL AS mf_code, NULL AS mf_id, NULL AS quant_unit, NULL AS quant_unit_id, s0.prec
FROM (
	SELECT q.q_i AS qi_combo, q.r_i AS ri_combo, x.df_code, x.df_id, x.dfg_id, x.bn_code, x.bn_id, x.prec
	FROM x_pattern x
	JOIN qr_i q ON q.qi_combo = x.qi_combo
		AND q.ri_combo = x.ri_combo -- get right component in a combination aligned
	WHERE x.qd_combo IS NULL -- only Form patterns
		AND x.qi_combo LIKE '%-%' -- only combinations, otherwise nothing to break up
	
	EXCEPT
	
	SELECT qi_combo, ri_combo, df_code, df_id, dfg_id, bn_code, bn_id, prec
	FROM x_pattern
	) AS s0;

-- 27-28. If nothing works and no patterns exist, add the best translations (usually Clinical Drug Comps with no descendants)
-- Pick the best translation for each qd_combo and quant_unit_id, so there is a choice when combining in extension_combo
INSERT INTO x_pattern
SELECT q0.*,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 27 -- solid drug
		WHEN xu.precedence = 1
			THEN 27 -- quant_unit and quant_unit_id match according to prec
		ELSE 28
		END AS prec
FROM (
	SELECT DISTINCT q.qi_combo,
		FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qd_combo,
			q.quant_unit_id ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS ri_combo,
		q.qd_combo,
		FIRST_VALUE(q.rd_combo) OVER (
			PARTITION BY q.qd_combo,
			q.quant_unit_id ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS rd_combo,
		NULL AS df_code,
		NULL::INT AS df_id,
		NULL::INT AS dfg_id,
		NULL AS bn_code,
		NULL::INT AS bn_id,
		NULL AS mf_code,
		NULL::INT AS mf_id,
		FIRST_VALUE(q.quant_unit) OVER (
			PARTITION BY q.qd_combo,
			q.quant_unit_id ORDER BY q.div DESC,
				q.i_prec,
				q.u_prec
			) AS quant_unit,
		quant_unit_id
	FROM qr_d_combo q
	) q0
-- compare to existing to make sure pattern isn't already covered
LEFT JOIN x_unit xu ON xu.unit_code = q0.quant_unit
	AND xu.unit_id = q0.quant_unit_id
LEFT JOIN x_pattern x ON q0.qd_combo = x.qd_combo
	AND q0.quant_unit_id = x.quant_unit_id
WHERE x.rd_combo IS NULL;

-- 29-30. Add i_combos that are not in x_pattern, but can be inferred from qr_i_combo (singleton drug forms)
INSERT INTO x_pattern
SELECT s0.qi_combo, s0.ri_combo, NULL AS qd_combo, NULL AS rd_combo, NULL AS df_code, NULL AS df_id, NULL AS dfg_id, NULL AS bn_code, NULL AS bn_id, NULL AS mf_code, NULL AS mf_id, NULL AS quant_unit, NULL AS quant_unit_id, 29 + s0.new_rec AS prec
FROM (
	SELECT DISTINCT q.qi_combo, FIRST_VALUE(q.ri_combo) OVER (
			PARTITION BY q.qi_combo ORDER BY q.i_prec
			) AS ri_combo, 1 AS new_rec
	FROM qr_i_combo q
	-- Make sure it is not already covered
	-- compare to existing to make sure pattern isn't already covered
	
	UNION ALL
	
	SELECT DISTINCT qi_combo, ri_combo, 0 AS new_rec
	FROM x_pattern
	) AS s0;

-- 31. Add single ingredient translations not found in the data, but provided by the input tables and have drugs containing them
INSERT INTO x_pattern
SELECT DISTINCT q.qi_code AS qi_combo,
	FIRST_VALUE(q.ri_code) OVER (
		PARTITION BY q.qi_code ORDER BY q.prec
		) AS ri_combo, -- pick the best translation
	NULL AS qd_combo,
	NULL AS rd_combo,
	NULL AS df_code,
	NULL::INT AS df_id,
	NULL::INT AS dfg_id,
	NULL AS bn_code,
	NULL::INT AS bn_id,
	NULL AS mf_code,
	NULL::INT AS mf_id,
	NULL AS quant_unit,
	NULL::INT AS quant_unit_id,
	31 AS prec
FROM qr_ing q
WHERE NOT EXISTS (
		SELECT 1
		FROM x_pattern x_p_int
		WHERE x_p_int.qi_combo = q.qi_code
		);

-- 32. and 33. All untranslatable are going to be added from extension_combo to x_pattern

-- Create individual translation tables all starting with x_, with one best record for each q *
-- Strategy: First use what's found in the patterns, then use precedences from relationship_to_concept and div between uds

-- Translation of individual ingredients, whether found in r or not
-- x_pattern is for i_combo translations in Drug Forms, x_ing for translations of individual ingredients, such as in extension_uds
-- Get all the ones in x_pattern, which contains everything that is translated somewhere
DROP TABLE IF EXISTS x_ing;
CREATE UNLOGGED TABLE x_ing AS
SELECT DISTINCT s0.qi_combo,
	FIRST_VALUE(s0.ri_combo) OVER (
		PARTITION BY s0.qi_combo ORDER BY s0.prec,
			s0.cnt DESC,
			s0.qi_combo
		) AS ri_combo
FROM (
	SELECT qi_combo,
		ri_combo,
		prec,
		COUNT(*) AS cnt
	FROM x_pattern
	WHERE ri_combo NOT LIKE '%-%'
	GROUP BY qi_combo,
		ri_combo,
		prec
	) AS s0;

-- Add any translations not found in the data, but provided by the input tables even if no drug contains them
-- (x_i_combo contains only ingredients that have a drug as a descendent)
INSERT INTO x_ing
SELECT DISTINCT rtc.concept_code_1 AS qi_combo,
	FIRST_VALUE(i.i_code) OVER (
		PARTITION BY rtc.concept_code_1 ORDER BY rtc.precedence
		) AS ri_combo -- pick the best translation
FROM r_to_c rtc
JOIN ing_stage i ON i.i_id = rtc.concept_id_2 -- limit to ingredients and get xxx-code
WHERE NOT EXISTS (
		SELECT 1
		FROM x_ing x_int
		WHERE x_int.qi_combo = rtc.concept_code_1
		);

-- Preferred Dose Form translations. These may be a little optimistic, as DFGs are fairly broad
DROP TABLE IF EXISTS x_df;
CREATE UNLOGGED TABLE x_df AS
SELECT DISTINCT s0.df_code,
	FIRST_VALUE(s0.df_id) OVER (
		PARTITION BY s0.df_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.df_id
		) AS df_id, -- pick the most common translation in the data
	FIRST_VALUE(d.dfg_id) OVER (
		PARTITION BY s0.df_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.df_id
		) AS dfg_id, -- pick the most common translation in the data
	FIRST_VALUE(c.concept_name) OVER (
		PARTITION BY s0.df_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.df_id
		) AS concept_name -- and the corresponding name
FROM (
	SELECT df_code,
		df_id,
		prec,
		COUNT(*) AS cnt
	FROM x_pattern
	WHERE df_id <> 0
	GROUP BY df_code,
		df_id,
		prec
	) AS s0
JOIN concept c ON c.concept_id = s0.df_id
LEFT JOIN dfg d ON d.df_id = s0.df_id;

-- Add the ones that are not translated in the data
INSERT INTO x_df
SELECT q.df_code,
	q.df_id,
	d.dfg_id,
	c.concept_name
FROM qr_df q
JOIN concept c ON c.concept_id = q.df_id
LEFT JOIN dfg d ON d.df_id = q.df_id
WHERE NOT EXISTS (
		SELECT 1
		FROM x_df x_int
		WHERE x_int.df_code = q.df_code
		) -- don't translate the ones already there
	AND q.df_prec = 1;

-- Preferred Brand Name translations. Usually brands are one-to-one
DROP TABLE IF EXISTS x_bn;
CREATE UNLOGGED TABLE x_bn AS
SELECT DISTINCT s0.bn_code,
	FIRST_VALUE(s0.bn_id) OVER (
		PARTITION BY s0.bn_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.bn_id
		) AS bn_id, -- pick the most common translation in the data
	FIRST_VALUE(c.concept_name) OVER (
		PARTITION BY s0.bn_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.bn_id
		) AS concept_name
FROM (
	SELECT bn_code,
		bn_id,
		prec,
		COUNT(*) AS cnt
	FROM x_pattern
	WHERE bn_id <> 0
	GROUP BY bn_code,
		bn_id,
		prec
	) AS s0
JOIN concept c ON c.concept_id = s0.bn_id;

-- Add the ones that are not translated in the data
INSERT INTO x_bn
SELECT q.bn_code,
	q.bn_id,
	c.concept_name
FROM qr_bn q
JOIN concept c ON c.concept_id = q.bn_id
WHERE NOT EXISTS (
		SELECT 1
		FROM x_bn x_int
		WHERE x_int.bn_code = q.bn_code
		) -- don't translate the ones already there
	AND q.bn_prec = 1;

-- Preferred Supplier translations
DROP TABLE IF EXISTS x_mf;
CREATE UNLOGGED TABLE x_mf AS
SELECT DISTINCT s0.mf_code,
	FIRST_VALUE(s0.mf_id) OVER (
		PARTITION BY s0.mf_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.mf_id
		) AS mf_id, -- pick the most common translation in the data
	FIRST_VALUE(c.concept_name) OVER (
		PARTITION BY s0.mf_code ORDER BY s0.prec,
			s0.cnt DESC,
			s0.mf_id
		) AS concept_name
FROM (
	SELECT mf_code,
		mf_id,
		prec,
		COUNT(*) AS cnt
	FROM x_pattern
	WHERE mf_id <> 0
	GROUP BY mf_code,
		mf_id,
		prec
	) AS s0
JOIN concept c ON c.concept_id = s0.mf_id;

-- Add the ones that are not translated in the data
INSERT INTO x_mf
SELECT q.mf_code,
	q.mf_id,
	c.concept_name
FROM qr_mf q
JOIN concept c ON c.concept_id = q.mf_id
WHERE NOT EXISTS (
		SELECT 1
		FROM x_mf x_int
		WHERE x_int.mf_code = q.mf_code
		) -- don't translate the ones already there
	AND q.mf_prec = 1;

/*********************************************************
* 8. Build extensions for ing, uds, combo, df, bn and mf *
*********************************************************/

-- Create table with ingredients in q that have no translation
-- Ingredient combinations are in extension_ds, even if d_combo doesn't exist
DROP TABLE IF EXISTS extension_i;
CREATE UNLOGGED TABLE extension_i AS
SELECT i_code AS qi_code,
	'XXX' || NEXTVAL('xxx_seq') AS ri_code
FROM (
	-- all ingredients that have no translation
	SELECT DISTINCT i_code
	FROM q_ing q
	WHERE NOT EXISTS (
			SELECT 1
			FROM x_ing x_int
			WHERE x_int.qi_combo = q.i_code
			)
	ORDER BY i_code --just for sequence repeatability
	) AS s0;

-- Create table with unique ds in q that have no translation
-- Use the direct translation resulting in a conversion_factor=1
DROP TABLE IF EXISTS extension_uds;
CREATE UNLOGGED TABLE extension_uds AS
SELECT q.*
FROM (
	SELECT qu.ds_code, -- the original ds_code from q_combo can be used as there is a one-to-one relationship (no ingredient or unit splitting)
		s0.ri_code AS i_code,
		0 AS ingredient_concept_id, -- only placeholder so extension_uds can be unioned with r_uds later
		qu.amount_value * COALESCE(xu_a.conversion_factor, 1) AS amount_value,
		COALESCE(xu_a.unit_id, 0) AS amount_unit_concept_id,
		qu.numerator_value * COALESCE(xu_n.conversion_factor, 1) / COALESCE(xu_d.conversion_factor, 1) AS numerator_value,
		COALESCE(xu_n.unit_id, 0) AS numerator_unit_concept_id,
		CASE -- don't replace null in denominator_unit with 0 for the homeopathics and 0
			WHEN xu_n.unit_id IN (
					8554,
					9325,
					9324
					)
				THEN NULL
			ELSE COALESCE(xu_d.unit_id, 0)
			END AS denominator_unit_concept_id
	FROM q_uds qu
	JOIN (
		-- translate the ingredient
		SELECT *
		FROM extension_i
		
		UNION
		
		SELECT qi_combo,
			ri_combo
		FROM x_ing -- use only the generic, not pattern specific translation in x_pattern
		) AS s0 ON s0.qi_code = qu.ingredient_concept_code
	-- translate the units
	LEFT JOIN x_unit xu_a ON xu_a.unit_code = qu.amount_unit
		AND xu_a.precedence = 1
	LEFT JOIN x_unit xu_n ON xu_n.unit_code = qu.numerator_unit
		AND xu_n.precedence = 1
	LEFT JOIN x_unit xu_d ON xu_d.unit_code = qu.denominator_unit
		AND xu_d.precedence = 1
	) q
-- check whether or not we have the qd_combo (ds_code)-quant_unit_id combination
WHERE NOT EXISTS (
		SELECT 1
		FROM x_pattern x_int
		WHERE x_int.qd_combo NOT LIKE '%-%' -- excluding the combos, otherwise cast as number won't work
			AND x_int.qd_combo = q.ds_code
			AND COALESCE(x_int.quant_unit_id, - 1) = COALESCE(q.denominator_unit_concept_id, - 1)
		);

-- Create list of identical extension_uds (different q_uds, but after translation identical)
DROP TABLE IF EXISTS reduce_euds;
CREATE UNLOGGED TABLE reduce_euds AS
SELECT DISTINCT ds_code AS from_code,
	FIRST_VALUE(ds_code) OVER (
		PARTITION BY i_code,
		ingredient_concept_id,
		amount_value,
		amount_unit_concept_id,
		numerator_value,
		numerator_unit_concept_id,
		COALESCE(denominator_unit_concept_id, - 1) ORDER BY ds_code
		) AS to_code
FROM extension_uds;

-- Create table linking the q and translated r or extended uds to their q combos (including all singletons)
-- Translated q_uds could be multiple, the best (lowest prec) for each quant_unit_id 
DROP TABLE IF EXISTS extension_ds;
CREATE UNLOGGED TABLE extension_ds AS
SELECT DISTINCT s0.i_combo,
	s0.d_combo,
	s3.q_ds,
	s3.r_ds,
	s0.q_i,
	s3.r_i,
	s0.quant_unit,
	s3.quant_unit_id
FROM (
	-- for each non-translated q_combo get individual ds, i_code and i_combo
	SELECT qc.i_combo,
		qc.d_combo,
		q1.ds_code,
		q1.i_code AS q_i,
		q1.quant_unit
	FROM q_combo qc
	JOIN q_ds q1 ON q1.concept_code = qc.concept_code
	WHERE NOT EXISTS (
			-- those that already have a translation
			SELECT 1
			FROM x_pattern x_int
			WHERE x_int.qd_combo = qc.d_combo
			)
		AND EXISTS (
			SELECT 1
			FROM q_uds q_int
			WHERE q_int.ds_code = q1.ds_code
			)
	
	UNION ALL -- union all singletons for Clin Comps, q_combo has only those that are mentioned in q
	
	SELECT i_code,
		ds_code,
		ds_code,
		i_code,
		quant_unit
	FROM q_ds
	) AS s0
JOIN (
	-- translations for the ds_code in q_ds to r notation (either extension or x_pattern singletons)
	-- get the newly defined uds from extension_uds
	SELECT u.ds_code AS q_ds,
		ru.to_code AS r_ds,
		u.i_code AS r_i,
		u.denominator_unit_concept_id AS quant_unit_id
	FROM extension_uds u
	JOIN reduce_euds ru ON ru.from_code = u.ds_code
	
	UNION ALL -- and the translated ones since they get mixed with the new ones in combos
	
	SELECT s2.qd_combo AS q_ds,
		COALESCE(ru.to_code, s2.rd) AS r_ds,
		s2.ri_combo AS r_i,
		s2.quant_unit_id
	FROM (
		SELECT DISTINCT s1.qd_combo,
			FIRST_VALUE(s1.rd_combo) OVER (
				PARTITION BY s1.qd_combo,
				s1.quant_unit_id ORDER BY s1.prec,
					s1.cnt DESC,
					s1.rd_combo
				) AS rd, -- get the best translation for each quant_unit_id
			FIRST_VALUE(s1.ri_combo) OVER (
				PARTITION BY s1.qd_combo,
				s1.quant_unit_id ORDER BY s1.prec,
					s1.cnt DESC,
					s1.rd_combo
				) AS ri_combo,
			s1.quant_unit_id
		-- count translations for each quant_unit_id
		FROM (
			SELECT qd_combo,
				rd_combo,
				ri_combo,
				quant_unit_id,
				MIN(prec) AS prec,
				COUNT(*) AS cnt
			FROM x_pattern
			WHERE qd_combo NOT LIKE '%-%'
			GROUP BY qd_combo,
				rd_combo,
				ri_combo,
				quant_unit_id
			) AS s1
		) AS s2
	LEFT JOIN reduce_euds ru ON ru.from_code = s2.rd
	) AS s3 ON s3.q_ds = s0.ds_code;

-- Create combos for extension. Existing combos in x_pattern will not be added, but any combination of existing and new uds might get in
-- Only the best combination with a matching quant_unit_id will be created (not all that can be inferred from x_pattern).
-- Not all combos will actually be used, as some drugs are mapped 100%
-- Combos may combine quant_unit_ids with nulls (% and homeopathics), they have to be resolved to the other ones
DROP TABLE IF EXISTS extension_combo;
CREATE UNLOGGED TABLE extension_combo AS
	WITH denom AS (
			-- create list of all quant units
			SELECT denominator_unit_concept_id AS qid
			FROM extension_uds
			WHERE denominator_unit_concept_id IS NOT NULL
			
			UNION
			
			SELECT denominator_unit_concept_id
			FROM r_uds
			WHERE denominator_unit_concept_id IS NOT NULL
			),
		all_quant AS (
			-- create a list of translations of quant units to self, or null to everyone
			SELECT qid AS quant_unit_id,
				qid
			FROM denom -- translate unit to itself
			
			UNION
			
			SELECT - 1 AS quant_unit_id,
				qid
			FROM denom -- translate -1 (null) into all possibilities
			)
SELECT DISTINCT s1.qi_combo,
	s1.ri_combo,
	s1.qd_combo,
	s1.rd_combo,
	s1.quant_unit,
	CASE 
		WHEN s1.quant_unit IS NULL
			THEN NULL
		ELSE s1.quant_unit_id
		END AS quant_unit_id -- restore a quant unit of null if not used in combination
FROM (
	SELECT s0.i_combo AS qi_combo,
		STRING_AGG(s0.r_i, '-' ORDER BY s0.r_i) AS ri_combo,
		s0.d_combo AS qd_combo,
		STRING_AGG(s0.q_ds, '-' ORDER BY LPAD(s0.q_ds, 20, '0')) AS qd_check,
		STRING_AGG(s0.r_ds, '-' ORDER BY LPAD(s0.r_ds, 20, '0')) AS rd_combo,
		MAX(s0.quant_unit) AS quant_unit,
		s0.quant_unit_id
	FROM (
		-- split null in quant_unit_id into all possible values
		-- this will create a cartesian product if several components have quant_unit_id is null, but this is rare and therefore tolerable
		SELECT eds.i_combo,
			eds.d_combo,
			eds.q_ds,
			eds.r_ds,
			eds.q_i,
			eds.r_i,
			eds.quant_unit,
			a.qid AS quant_unit_id
		FROM extension_ds eds
		JOIN all_quant a ON a.quant_unit_id = COALESCE(eds.quant_unit_id, - 1)
		) AS s0
	GROUP BY s0.i_combo,
		s0.d_combo,
		s0.quant_unit_id -- make sure there is only one quant_unit_id in the combo
	) AS s1
WHERE s1.qd_combo = s1.qd_check;-- make sure what gets assembled has the same components (all same quant_unit_id)

-- Add ingredient only combos for Drug Forms.
INSERT INTO extension_combo
SELECT s0.i_combo AS qi_combo,
	STRING_AGG(s1.ri_code, '-' ORDER BY s1.ri_code) AS ri_combo,
	NULL AS qd_combo,
	NULL AS rd_combo,
	NULL AS quant_unit,
	NULL AS quant_unit_id
FROM (
	-- i_combos in q_combo but not translated (x_i_combo) or added through d_combo
	SELECT DISTINCT qi.i_code,
		qc.i_combo
	FROM q_combo qc
	JOIN q_ing qi ON qi.concept_code = qc.concept_code
	WHERE qc.d_combo = ' '
		AND NOT EXISTS (
			-- those that already have a translation
			SELECT 1
			FROM x_pattern x_int
			WHERE x_int.qi_combo = qc.i_combo
			)
		AND NOT EXISTS (
			-- those we already got covered
			SELECT 1
			FROM extension_combo ec_int
			WHERE ec_int.qi_combo = qc.i_combo
			)
	) AS s0
JOIN (
	-- translate the ingredient
	SELECT *
	FROM extension_i
	
	UNION
	
	SELECT *
	FROM x_ing -- use only the generic, not specific translation
	) AS s1 ON s1.qi_code = s0.i_code
GROUP BY s0.i_combo;

-- Add to x_pattern as least preferred translation
INSERT INTO x_pattern
SELECT ec.qi_combo,
	ec.ri_combo,
	ec.qd_combo,
	ec.rd_combo,
	NULL AS df_code,
	NULL AS df_id,
	NULL AS dfg_id,
	NULL AS bn_code,
	NULL AS bn_id,
	NULL AS mf_code,
	NULL AS mf_id,
	ec.quant_unit,
	ec.quant_unit_id,
	CASE -- if the translation keeps the favorite quant_unit_id give it a better prec 
		WHEN xu.precedence IS NULL
			THEN 33 -- solid drug
		WHEN xu.precedence = 1
			THEN 33 -- quant_unit and quant_unit_id match according to prec
		ELSE 33
		END AS prec
FROM extension_combo ec
LEFT JOIN x_unit xu ON xu.unit_code = ec.quant_unit
	AND xu.unit_id = ec.quant_unit_id
LEFT JOIN x_pattern xp ON xp.qi_combo = ec.qi_combo
	AND xp.ri_combo = ec.ri_combo
	AND xp.qd_combo = ec.qd_combo
	AND xp.rd_combo = ec.rd_combo
	AND xp.quant_unit = ec.quant_unit
	AND xp.quant_unit_id = ec.quant_unit_id
WHERE xp.prec IS NULL;

-- Create DF extension records for those Dose Forms that don't exist
DROP TABLE IF EXISTS extension_df;
CREATE UNLOGGED TABLE extension_df AS
SELECT s1.df_code,
	s1.concept_name,
	NEXTVAL('extension_id') AS df_id
FROM (
	SELECT dcs.concept_code AS df_code,
		dcs.concept_name
	FROM drug_concept_stage dcs
	WHERE EXISTS (
			SELECT 1
			FROM q_df q_int
			WHERE q_int.df_code = dcs.concept_code
			)
		AND NOT EXISTS (
			SELECT 1
			FROM x_df x_int
			WHERE x_int.df_code = dcs.concept_code
			) -- those that already have a translation
	ORDER BY dcs.concept_code
	) AS s1;

-- Create BN extension records for those Dose Forms that do not exist
DROP TABLE IF EXISTS extension_bn;
CREATE UNLOGGED TABLE extension_bn AS
SELECT s1.bn_code,
	s1.concept_name,
	NEXTVAL('extension_id') AS bn_id
FROM (
	SELECT dcs.concept_code AS bn_code,
		dcs.concept_name
	FROM drug_concept_stage dcs
	WHERE EXISTS (
			SELECT 1
			FROM q_bn q_int
			WHERE q_int.bn_code = dcs.concept_code
			)
		AND NOT EXISTS (
			SELECT 1
			FROM x_bn x_int
			WHERE x_int.bn_code = dcs.concept_code
			) -- those that already have a translation
	ORDER BY dcs.concept_code
	) AS s1;

-- Create MF extension records for those Dose Forms that don't exist
DROP TABLE IF EXISTS extension_mf;
CREATE TABLE extension_mf AS
SELECT s1.mf_code,
	s1.concept_name,
	NEXTVAL('extension_id') AS mf_id
FROM (
	SELECT dcs.concept_code AS mf_code,
		dcs.concept_name
	FROM drug_concept_stage dcs
	WHERE EXISTS (
			SELECT 1
			FROM q_mf q_int
			WHERE q_int.mf_code = dcs.concept_code
			)
		AND NOT EXISTS (
			SELECT 1
			FROM x_mf x_int
			WHERE x_int.mf_code = dcs.concept_code
			) -- those that already have a translation
	ORDER BY dcs.concept_code
	) AS s1;


/*******************************************************************************************************************
* 9. Build a complete target corpus in both q and r notation and assign concept_code from q and concept_id from r *
*******************************************************************************************************************/

-- Marketed Product
-- Definition: d_combo, df and mf must exist, quant, bn and bs are optional
DROP TABLE IF EXISTS full_corpus;
CREATE UNLOGGED TABLE full_corpus AS
	WITH mp AS (
			-- Define all Marketed Products in q
			SELECT DISTINCT COALESCE(q4.value, 0) AS q_value,
				COALESCE(q4.unit, ' ') AS quant_unit,
				q1.i_combo AS qi_combo,
				q1.d_combo AS qd_combo,
				COALESCE(q2.df_code, ' ') AS df_code,
				COALESCE(q5.bn_code, ' ') AS bn_code,
				COALESCE(q6.bs, 0) AS bs,
				COALESCE(q3.mf_code, ' ') AS mf_code
			FROM q_combo q1
			JOIN q_df q2 ON q2.concept_code = q1.concept_code
			JOIN q_mf q3 ON q3.concept_code = q1.concept_code
			LEFT JOIN q_quant q4 ON q4.concept_code = q1.concept_code
			LEFT JOIN q_bn q5 ON q5.concept_code = q1.concept_code
			LEFT JOIN q_bs q6 ON q6.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' ' -- to exclude "Marketed Branded Drug Forms" without strength
			)
SELECT s0.concept_code, s1.concept_id, m.q_value, m.quant_unit, m.qi_combo, m.qd_combo, m.df_code, m.bn_code, m.bs, m.mf_code, m.r_value,m.quant_unit_id, m.ri_combo, m.rd_combo, m.df_id, m.bn_id, m.mf_id, 'Marketed Product' AS concept_class_id
FROM (
	SELECT p.q_value, p.quant_unit, p.qi_combo, p.qd_combo, p.df_code, p.bn_code, p.bs, p.mf_code, COALESCE(q.r_value, p.q_value * xu.conversion_factor, 0) AS r_value, 
	COALESCE(q.quant_unit_id, xu.unit_id, 0) AS quant_unit_id, p.ri_combo, p.rd_combo, p.df_id, p.bn_id, p.mf_id
	FROM (
		SELECT DISTINCT c.*,
			FIRST_VALUE(x.ri_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code,
				c.mf_code ORDER BY x.prec
				) AS ri_combo,
			FIRST_VALUE(x.rd_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code,
				c.mf_code ORDER BY x.prec
				) AS rd_combo,
			FIRST_VALUE(x.quant_unit_id) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code,
				c.mf_code ORDER BY x.prec
				) AS quant_unit_id,
			COALESCE(x.df_id, x1.df_id, edf.df_id, 0) AS df_id, -- pick from pattern, when no pattern from best translation, when no from new
			COALESCE(x.bn_id, x2.bn_id, ebn.bn_id, 0) AS bn_id,
			COALESCE(x.mf_id, x3.mf_id, emf.mf_id, 0) AS mf_id
		FROM mp c
		LEFT JOIN x_pattern x ON x.qd_combo = c.qd_combo
			AND COALESCE(x.df_code, c.df_code) = c.df_code
			AND COALESCE(x.bn_code, c.bn_code) = c.bn_code
			AND COALESCE(x.mf_code, c.mf_code) = c.mf_code
		LEFT JOIN x_df x1 ON x1.df_code = c.df_code
		LEFT JOIN extension_df edf ON edf.df_code = c.df_code
		LEFT JOIN x_bn x2 ON x2.bn_code = c.bn_code
		LEFT JOIN extension_bn ebn ON ebn.bn_code = c.bn_code
		LEFT JOIN x_mf x3 ON x3.mf_code = c.mf_code
		LEFT JOIN extension_mf emf ON emf.mf_code = c.mf_code
		) p
	LEFT JOIN qr_quant q ON q.q_value = p.q_value
		AND q.quant_unit = p.quant_unit
		AND q.quant_unit_id = COALESCE(p.quant_unit_id, q.quant_unit_id) -- q.quant_unit_id can be null in homeopathics and %
		-- If units are null (undefined, usually after % or the homeopathics), then match no matter what, after trying everything else
		-- if more than one match for unit_code (different conversion factors), pick the one that matches unit_id, and if that's null, pick the one which is 1
	LEFT JOIN x_unit xu ON xu.unit_code = p.quant_unit
		AND xu.unit_id = COALESCE(p.quant_unit_id, xu.unit_id)
		AND xu.conversion_factor = CASE 
			WHEN p.quant_unit_id IS NULL
				THEN 1
			ELSE xu.conversion_factor
			END
	) m
LEFT JOIN (
	SELECT concept_code, quant_value AS q_value, quant_unit, i_combo AS qi_combo, d_combo AS qd_combo, df_code, bn_code, bs, mf_code
	FROM q_existing
	) AS s0 ON s0.q_value = m.q_value
	AND s0.quant_unit = m.quant_unit
	AND s0.qi_combo = m.qi_combo
	AND s0.qd_combo = m.qd_combo
	AND s0.df_code = m.df_code
	AND s0.bn_code = m.bn_code
	AND s0.bs = m.bs
	AND s0.mf_code = m.mf_code
LEFT JOIN (
	SELECT concept_id, quant_value AS r_value, quant_unit_id, i_combo AS ri_combo, d_combo AS rd_combo, df_id, bn_id, bs, mf_id
	FROM r_existing
	) AS s1 ON s1.r_value = m.r_value
	AND s1.quant_unit_id = m.quant_unit_id
	AND s1.ri_combo = m.ri_combo
	AND s1.rd_combo = m.rd_combo
	AND s1.df_id = m.df_id
	AND s1.bn_id = m.bn_id
	AND s1.bs = m.bs
	AND s1.mf_id = m.mf_id;

-- Branded Products (quant, boxed or just Drug)
-- Definition: d_combo, df and bn, no mf, quant and bs optional
INSERT INTO full_corpus
WITH ex AS (
		-- Quant Branded Box
		SELECT q_value, quant_unit, qi_combo, qd_combo, df_code, bn_code, bs, r_value, quant_unit_id, ri_combo, rd_combo, df_id, bn_id
		FROM full_corpus
		WHERE df_id <> 0
			AND bn_id <> 0

		UNION

		-- Branded Box
		SELECT 0 AS q_value, ' ' AS quant_unit, qi_combo, qd_combo, df_code, bn_code, bs, 0 AS r_value, 0 AS quant_unit_id, ri_combo, rd_combo, df_id, bn_id
		FROM full_corpus
		WHERE df_id <> 0
			AND bn_id <> 0

		UNION

		-- Quant Branded Drug
		SELECT q_value, quant_unit, qi_combo, qd_combo, df_code, bn_code, 0 AS bs, r_value, quant_unit_id, ri_combo, rd_combo, df_id, bn_id
		FROM full_corpus
		WHERE df_id <> 0
			AND bn_id <> 0

		UNION

		-- Branded Drug
		SELECT 0 AS q_value, ' ' AS quant_unit, qi_combo, qd_combo, df_code, bn_code, 0 AS bs, 0 AS r_value, 0 AS quant_unit_id, ri_combo, rd_combo, df_id, bn_id
		FROM full_corpus
		WHERE df_id <> 0
			AND bn_id <> 0
		),
	c AS (
		SELECT *
		FROM (
			-- Quant Branded Box
			SELECT q2.value AS q_value, q2.unit AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q3.df_code, q4.bn_code, q5.bs
			FROM q_combo q1
			JOIN q_quant q2 ON q2.concept_code = q1.concept_code
			JOIN q_df q3 ON q3.concept_code = q1.concept_code
			JOIN q_bn q4 ON q4.concept_code = q1.concept_code
			JOIN q_bs q5 ON q5.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Branded Drug Box
			SELECT 0 AS q_value, ' ' AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q2.df_code, q3.bn_code, q4.bs
			FROM q_combo q1
			JOIN q_df q2 ON q2.concept_code = q1.concept_code
			JOIN q_bn q3 ON q3.concept_code = q1.concept_code
			JOIN q_bs q4 ON q4.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Quant Branded Drug
			SELECT q2.value AS q_value, q2.unit AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q3.df_code, q4.bn_code, 0 AS bs
			FROM q_combo q1
			JOIN q_quant q2 ON q2.concept_code = q1.concept_code
			JOIN q_df q3 ON q3.concept_code = q1.concept_code
			JOIN q_bn q4 ON q4.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Branded Drug
			SELECT 0 AS q_value, ' ' AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q2.df_code, q3.bn_code, 0 AS bs
			FROM q_combo q1
			JOIN q_df q2 ON q2.concept_code = q1.concept_code
			JOIN q_bn q3 ON q3.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '
			) AS s0
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT q_value, quant_unit, qi_combo, qd_combo, df_code, bn_code, bs
		FROM ex
		)
SELECT s0.concept_code, s1.concept_id, m.q_value, m.quant_unit, m.qi_combo, m.qd_combo, m.df_code, m.bn_code, m.bs,
	' ' AS mf_code, m.r_value, m.quant_unit_id, m.ri_combo, m.rd_combo, m.df_id, m.bn_id, 0 AS mf_id,
	CASE 
		WHEN m.q_value = 0
			AND m.bs = 0
			THEN 'Branded Drug'
		WHEN m.q_value = 0
			THEN 'Branded Drug Box'
		WHEN m.bs = 0
			THEN 'Quant Branded Drug'
		ELSE 'Quant Branded Box'
		END AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT p.q_value, p.quant_unit, p.qi_combo, p.qd_combo, p.df_code, p.bn_code, p.bs, COALESCE(q.r_value, p.q_value * xu.conversion_factor, 0) AS r_value, COALESCE(q.quant_unit_id, xu.unit_id, 0) AS quant_unit_id, p.ri_combo, p.rd_combo, p.df_id, p.bn_id
	FROM (
		SELECT DISTINCT c.*,
			FIRST_VALUE(x.ri_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code ORDER BY x.prec
				) AS ri_combo,
			FIRST_VALUE(x.rd_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code ORDER BY x.prec
				) AS rd_combo,
			FIRST_VALUE(x.quant_unit_id) OVER (
				PARTITION BY c.qd_combo,
				c.df_code,
				c.bn_code ORDER BY x.prec
				) AS quant_unit_id,
			COALESCE(x.df_id, x1.df_id, edf.df_id, 0) AS df_id,
			COALESCE(x.bn_id, x2.bn_id, ebn.bn_id, 0) AS bn_id
		FROM c
		LEFT JOIN x_pattern x ON x.qd_combo = c.qd_combo
			AND COALESCE(x.df_code, c.df_code) = c.df_code
			AND COALESCE(x.bn_code, c.bn_code) = c.bn_code
		LEFT JOIN x_df x1 ON x1.df_code = c.df_code
		LEFT JOIN extension_df edf ON edf.df_code = c.df_code
		LEFT JOIN x_bn x2 ON x2.bn_code = c.bn_code
		LEFT JOIN extension_bn ebn ON ebn.bn_code = c.bn_code
		) p
	LEFT JOIN qr_quant q ON q.q_value = p.q_value
		AND q.quant_unit = p.quant_unit
		AND q.quant_unit_id = COALESCE(p.quant_unit_id, q.quant_unit_id) -- q.quant_unit_id can be null in homeopathics and %
	LEFT JOIN x_unit xu ON xu.unit_code = p.quant_unit
		AND xu.unit_id = COALESCE(p.quant_unit_id, xu.unit_id)
		AND xu.conversion_factor = CASE 
			WHEN p.quant_unit_id IS NULL
				THEN 1
			ELSE xu.conversion_factor
			END
	) m
LEFT JOIN (
	SELECT concept_code, quant_value AS q_value, quant_unit, i_combo AS qi_combo, d_combo AS qd_combo, df_code, bn_code, bs
	FROM q_existing
	WHERE mf_code = ' '
	) AS s0 ON s0.q_value = m.q_value
	AND s0.quant_unit = m.quant_unit
	AND s0.qi_combo = m.qi_combo
	AND s0.qd_combo = m.qd_combo
	AND s0.df_code = m.df_code
	AND s0.bn_code = m.bn_code
	AND s0.bs = m.bs
LEFT JOIN (
	SELECT concept_id, quant_value AS r_value, quant_unit_id, i_combo AS ri_combo, d_combo AS rd_combo, df_id, bn_id, bs
	FROM r_existing
	WHERE mf_id = 0
	) AS s1 ON s1.r_value = m.r_value
	AND s1.quant_unit_id = m.quant_unit_id
	AND s1.ri_combo = m.ri_combo
	AND s1.rd_combo = m.rd_combo
	AND s1.df_id = m.df_id
	AND s1.bn_id = m.bn_id
	AND s1.bs = m.bs;

-- Clinical Products (quant, boxed or just Drug)
-- Definition: d_combo, df, no bn and mf, quant and bs optional
INSERT INTO full_corpus
WITH ex AS (
		-- Quant Clinical Box
		SELECT q_value, quant_unit, qi_combo, qd_combo, df_code, bs, r_value, quant_unit_id, ri_combo, rd_combo, df_id
		FROM full_corpus
		WHERE df_id <> 0

		UNION

		-- Clinical Box
		SELECT 0 AS q_value, ' ' AS quant_unit, qi_combo, qd_combo, df_code, bs, 0 AS r_value, 0 AS quant_unit_id, ri_combo, rd_combo, df_id
		FROM full_corpus
		WHERE df_id <> 0

		UNION

		-- Quant Clinical Drug
		SELECT q_value, quant_unit, qi_combo, qd_combo, df_code, 0 AS bs, r_value, quant_unit_id, ri_combo, rd_combo, df_id
		FROM full_corpus
		WHERE df_id <> 0

		UNION

		-- Clinical Drug
		SELECT 0 AS q_value, ' ' AS quant_unit, qi_combo, qd_combo, df_code, 0 AS bs, 0 AS r_value, 0 AS quant_unit_id, ri_combo, rd_combo, df_id
		FROM full_corpus
		WHERE df_id <> 0
		),
	c AS (
		SELECT *
		FROM (
			-- Quant Clinical Box
			SELECT q2.value AS q_value, q2.unit AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q3.df_code, q4.bs
			FROM q_combo q1
			JOIN q_quant q2 ON q2.concept_code = q1.concept_code
			JOIN q_df q3 ON q3.concept_code = q1.concept_code
			JOIN q_bs q4 ON q4.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Clinical Drug Box
			SELECT 0 AS q_value, ' ' AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q2.df_code, q3.bs
			FROM q_combo q1
			JOIN q_df q2 ON q2.concept_code = q1.concept_code
			JOIN q_bs q3 ON q3.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Quant Clinical Drug
			SELECT q2.value AS q_value, q2.unit AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q3.df_code, 0 AS bs
			FROM q_combo q1
			JOIN q_quant q2 ON q2.concept_code = q1.concept_code
			JOIN q_df q3 ON q3.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '

			UNION

			-- Clinical Drug
			SELECT 0 AS q_value, ' ' AS quant_unit, q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q2.df_code, 0 AS bs
			FROM q_combo q1
			JOIN q_df q2 ON q2.concept_code = q1.concept_code
			WHERE q1.d_combo <> ' '
			) AS s0
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT q_value,
			quant_unit,
			qi_combo,
			qd_combo,
			df_code,
			bs
		FROM ex
		)
SELECT s0.concept_code, s1.concept_id, m.q_value, m.quant_unit, m.qi_combo, m.qd_combo, m.df_code, ' ' AS bn_code, m.bs,
	' ' AS mf_code, m.r_value, m.quant_unit_id, m.ri_combo, m.rd_combo, m.df_id, 0 AS bn_id, 0 AS mf_id,
	CASE 
		WHEN m.q_value = 0
			AND m.bs = 0
			THEN 'Clinical Drug'
		WHEN m.q_value = 0
			THEN 'Clinical Drug Box'
		WHEN m.bs = 0
			THEN 'Quant Clinical Drug'
		ELSE 'Quant Clinical Box'
		END AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT p.q_value, p.quant_unit, p.qi_combo, p.qd_combo, p.df_code, p.bs, COALESCE(q.r_value, p.q_value * xu.conversion_factor, 0) AS r_value, COALESCE(q.quant_unit_id, xu.unit_id, 0) AS quant_unit_id, p.ri_combo, p.rd_combo, p.df_id
	FROM (
		SELECT DISTINCT c.*,
			FIRST_VALUE(x.ri_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code ORDER BY x.prec
				) AS ri_combo,
			FIRST_VALUE(x.rd_combo) OVER (
				PARTITION BY c.qd_combo,
				c.df_code ORDER BY x.prec
				) AS rd_combo,
			FIRST_VALUE(x.quant_unit_id) OVER (
				PARTITION BY c.qd_combo,
				c.df_code ORDER BY x.prec
				) AS quant_unit_id,
			COALESCE(x.df_id, x1.df_id, edf.df_id, 0) AS df_id
		FROM c
		LEFT JOIN x_pattern x ON x.qd_combo = c.qd_combo
			AND COALESCE(x.df_code, c.df_code) = c.df_code
		LEFT JOIN x_df x1 ON x1.df_code = c.df_code
		LEFT JOIN extension_df edf ON edf.df_code = c.df_code
		) p
	LEFT JOIN qr_quant q ON q.q_value = p.q_value
		AND q.quant_unit = p.quant_unit
		AND q.quant_unit_id = COALESCE(p.quant_unit_id, q.quant_unit_id) -- q.quant_unit_id can be null in homeopathics and %
	LEFT JOIN x_unit xu ON xu.unit_code = p.quant_unit
		AND xu.unit_id = COALESCE(p.quant_unit_id, xu.unit_id)
		AND xu.conversion_factor = CASE 
			WHEN p.quant_unit_id IS NULL
				THEN 1
			ELSE xu.conversion_factor
			END
	) m
LEFT JOIN (
	SELECT concept_code, quant_value AS q_value, quant_unit, i_combo AS qi_combo, d_combo AS qd_combo, df_code, bs
	FROM q_existing
	WHERE mf_code = ' '
		AND bn_code = ' '
	) AS s0 ON s0.q_value = m.q_value
	AND s0.quant_unit = m.quant_unit
	AND s0.qi_combo = m.qi_combo
	AND s0.qd_combo = m.qd_combo
	AND s0.df_code = m.df_code
	AND s0.bs = m.bs
LEFT JOIN (
	SELECT concept_id, quant_value AS r_value, quant_unit_id, i_combo AS ri_combo, d_combo AS rd_combo, df_id, bs
	FROM r_existing
	WHERE mf_id = 0
		AND bn_id = 0
	) AS s1 ON s1.r_value = m.r_value
	AND s1.quant_unit_id = m.quant_unit_id
	AND s1.ri_combo = m.ri_combo
	AND s1.rd_combo = m.rd_combo
	AND s1.df_id = m.df_id
	AND s1.bs = m.bs;

-- Branded Drug Form
-- Definition: i_combo, df and bn, no quant, d_combo, bs and mf
INSERT INTO full_corpus
WITH ex AS (
		SELECT DISTINCT qi_combo, df_code, bn_code, ri_combo, df_id, bn_id
		FROM full_corpus
		WHERE df_id <> 0
			AND bn_id <> 0
		),
	c AS (
		SELECT q1.i_combo AS qi_combo, q2.df_code, q3.bn_code
		FROM q_combo q1
		JOIN q_df q2 ON q2.concept_code = q1.concept_code
		JOIN q_bn q3 ON q3.concept_code = q1.concept_code
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT qi_combo, df_code, bn_code
		FROM ex
		)
SELECT s0.concept_code, s1.concept_id, 0 AS q_value, ' ' AS quant_unit, m.qi_combo, ' ' AS qd_combo, m.df_code, m.bn_code, 0 AS bs,
	' ' AS mf_code, 0 AS r_value, 0 AS quant_unit_id, m.ri_combo, ' ' AS rd_combo, m.df_id, m.bn_id, 0 AS mf_id, 'Branded Drug Form' AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT DISTINCT c.*,
		FIRST_VALUE(x.ri_combo) OVER (
			PARTITION BY c.qi_combo,
			c.df_code,
			c.bn_code ORDER BY x.prec
			) AS ri_combo,
		COALESCE(x.df_id, x1.df_id, edf.df_id, 0) AS df_id,
		COALESCE(x.bn_id, x2.bn_id, ebn.bn_id, 0) AS bn_id
	FROM c
	LEFT JOIN x_pattern x ON x.qi_combo = c.qi_combo
		AND COALESCE(x.df_code, c.df_code) = c.df_code
		AND COALESCE(x.bn_code, c.bn_code) = c.bn_code
	LEFT JOIN x_df x1 ON x1.df_code = c.df_code
	LEFT JOIN extension_df edf ON edf.df_code = c.df_code
	LEFT JOIN x_bn x2 ON x2.bn_code = c.bn_code
	LEFT JOIN extension_bn ebn ON ebn.bn_code = c.bn_code
	) m
LEFT JOIN (
	SELECT concept_code,
		i_combo AS qi_combo,
		df_code,
		bn_code
	FROM q_existing
	WHERE quant_value = 0
		AND d_combo = ' '
		AND bs = 0
		AND mf_code = ' '
	) AS s0 ON s0.qi_combo = m.qi_combo
	AND s0.df_code = m.df_code
	AND s0.bn_code = m.bn_code
LEFT JOIN (
	SELECT concept_id,
		i_combo AS ri_combo,
		df_id,
		bn_id
	FROM r_existing
	WHERE quant_value = 0
		AND d_combo = ' '
		AND bs = 0
		AND mf_id = 0
	) AS s1 ON s1.ri_combo = m.ri_combo
	AND s1.df_id = m.df_id
	AND s1.bn_id = m.bn_id;

-- Clinical Drug Form
-- Definition: i_combo and df, no quant, d_combo, bn, bs and mf
INSERT INTO full_corpus
WITH ex AS (
		SELECT DISTINCT qi_combo, df_code, ri_combo, df_id
		FROM full_corpus
		WHERE df_id <> 0
		),
	c AS (
		SELECT q1.i_combo AS qi_combo, q2.df_code
		FROM q_combo q1
		JOIN q_df q2 ON q2.concept_code = q1.concept_code
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT qi_combo, df_code
		FROM ex
		)
SELECT s0.concept_code, s1.concept_id, 0 AS q_value, ' ' AS quant_unit, m.qi_combo, ' ' AS qd_combo, m.df_code, ' ' AS bn_code, 0 AS bs,
	' ' AS mf_code, 0 AS r_value, 0 AS quant_unit_id, m.ri_combo, ' ' AS rd_combo, m.df_id, 0 AS bn_id, 0 AS mf_id, 'Clinical Drug Form' AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT DISTINCT c.*,
		FIRST_VALUE(x.ri_combo) OVER (
			PARTITION BY c.qi_combo,
			c.df_code ORDER BY x.prec
			) AS ri_combo,
		COALESCE(x.df_id, x1.df_id, edf.df_id, 0) AS df_id
	FROM c
	LEFT JOIN x_pattern x ON x.qi_combo = c.qi_combo
		AND COALESCE(x.df_code, c.df_code) = c.df_code
	LEFT JOIN x_df x1 ON x1.df_code = c.df_code
	LEFT JOIN extension_df edf ON edf.df_code = c.df_code
	) m
LEFT JOIN (
	SELECT concept_code,
		i_combo AS qi_combo,
		df_code
	FROM q_existing
	WHERE quant_value = 0
		AND d_combo = ' '
		AND bn_code = ' '
		AND bs = 0
		AND mf_code = ' '
	) AS s0 ON s0.qi_combo = m.qi_combo
	AND s0.df_code = m.df_code
LEFT JOIN (
	SELECT concept_id,
		i_combo AS ri_combo,
		df_id
	FROM r_existing
	WHERE quant_value = 0
		AND d_combo = ' '
		AND bn_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s1 ON s1.ri_combo = m.ri_combo
	AND s1.df_id = m.df_id;

-- Branded Drug Component
-- Definition: d_combo and bn, no quant, df, bs and mf
INSERT INTO full_corpus
WITH ex AS (
		SELECT DISTINCT qi_combo, qd_combo, bn_code, ri_combo, rd_combo, bn_id
		FROM full_corpus
		WHERE qd_combo <> ' '
			AND bn_id <> 0
		),
	c AS (
		SELECT q1.i_combo AS qi_combo, q1.d_combo AS qd_combo, q2.bn_code
		FROM q_combo q1
		JOIN q_bn q2 ON q2.concept_code = q1.concept_code
		WHERE q1.d_combo <> ' '
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT qi_combo,
			qd_combo,
			bn_code
		FROM ex
		)
SELECT s0.concept_code, s1.concept_id, 0 AS q_value, ' ' AS quant_unit, m.qi_combo, m.qd_combo, ' ' AS df_code, m.bn_code, 0 AS bs,
	' ' AS mf_code, 0 AS r_value, 0 AS quant_unit_id, m.ri_combo, m.rd_combo, 0 AS df_id, m.bn_id, 0 AS mf_id, 'Branded Drug Comp' AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT DISTINCT c.*,
		FIRST_VALUE(x.ri_combo) OVER (
			PARTITION BY c.qd_combo,
			c.bn_code ORDER BY x.prec
			) AS ri_combo,
		FIRST_VALUE(x.rd_combo) OVER (
			PARTITION BY c.qd_combo,
			c.bn_code ORDER BY x.prec
			) AS rd_combo,
		COALESCE(x.bn_id, x1.bn_id, ebn.bn_id, 0) AS bn_id
	FROM c
	LEFT JOIN x_pattern x ON x.qd_combo = c.qd_combo
		AND COALESCE(x.bn_code, c.bn_code) = c.bn_code
	LEFT JOIN x_bn x1 ON x1.bn_code = c.bn_code
	LEFT JOIN extension_bn ebn ON ebn.bn_code = c.bn_code
	) m
LEFT JOIN (
	SELECT concept_code,
		i_combo AS qi_combo,
		d_combo AS qd_combo,
		bn_code
	FROM q_existing
	WHERE quant_value = 0
		AND df_code = ' '
		AND bs = 0
		AND mf_code = ' '
	) AS s0 ON s0.qi_combo = m.qi_combo
	AND s0.qd_combo = m.qd_combo
	AND s0.bn_code = m.bn_code
LEFT JOIN (
	SELECT concept_id,
		i_combo AS ri_combo,
		d_combo AS rd_combo,
		bn_id
	FROM r_existing
	WHERE quant_value = 0
		AND df_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s1 ON s1.ri_combo = m.ri_combo
	AND s1.rd_combo = m.rd_combo
	AND s1.bn_id = m.bn_id;

-- Break up multi-ingredient ds and r for Clinical Drug Components
-- Note that q_breakup contains both singletons (those taht exist and those that are part of a combo, and combos. r_breakup contains only combos and needs to be unioned.
DROP TABLE IF EXISTS q_breakup;
CREATE UNLOGGED TABLE q_breakup AS
-- break up all rd_combos in q_combo
SELECT q1.d_combo AS qd_combo,
	q2.i_code AS q_i,
	q2.ds_code AS q_ds
FROM q_combo q1
JOIN q_ds q2 ON q2.concept_code = q1.concept_code

UNION

SELECT ds_code,
	ingredient_concept_code,
	ds_code
FROM q_uds;

DROP TABLE IF EXISTS r_breakup;
CREATE UNLOGGED TABLE r_breakup AS
SELECT s1.rd_combo,
	COALESCE(r.i_code, e.i_code) AS r_i,
	s1.ds_code AS r_ds
FROM (
	-- break up all rd_combos in x_pattern
	SELECT s0.rd_combo,
		TRIM(UNNEST(REGEXP_MATCHES(s0.rd_combo, '[^-]+', 'g'))) AS ds_code
	FROM (
		SELECT DISTINCT rd_combo
		FROM x_pattern
		WHERE rd_combo LIKE '%-%'
		) AS s0
	) AS s1
LEFT JOIN r_uds r ON r.ds_code = s1.ds_code
LEFT JOIN extension_uds e ON e.ds_code = s1.ds_code; -- get i_code

-- Clinical Drug Component
-- Definition: broken up d_combo, no quant, df, bn bs and mf
INSERT INTO full_corpus
WITH ex AS (
		SELECT DISTINCT q.q_i AS qi_combo,
			q.q_ds AS qd_combo,
			s1.r_i AS ri_combo,
			s1.r_ds AS rd_combo
		-- get all singleton translations
		FROM (
			SELECT DISTINCT qd_combo,
				rd_combo
			FROM full_corpus
			) AS s0
		-- break up qd_combo
		JOIN q_breakup q ON q.qd_combo = s0.qd_combo
		-- break up rd_combo
		JOIN (
			SELECT *
			FROM r_breakup -- break up combos
			
			UNION ALL
			
			SELECT rd_combo,
				ri_combo,
				rd_combo AS ds_code
			FROM x_pattern
			WHERE rd_combo NOT LIKE '%-%'
				AND rd_combo IS NOT NULL -- singletons
			) AS s1 ON s1.rd_combo = s0.rd_combo
		-- combine the ones that belong together
		JOIN (
			SELECT qi_code AS q_i,
				ri_code AS r_i
			FROM qr_ing
			
			UNION ALL
			
			SELECT qi_code,
				ri_code
			FROM extension_i
			) AS s2 ON s2.q_i = q.q_i
			AND s2.r_i = s1.r_i
		),
	c AS (
		SELECT q2.q_i AS qi_combo,
			q2.q_ds AS qd_combo
		FROM q_combo q1
		JOIN q_breakup q2 ON q2.qd_combo = q1.d_combo
		WHERE q1.d_combo <> ' '
		
		EXCEPT
		
		-- exclude the combinations already translated previously
		SELECT qi_combo,
			qd_combo
		FROM ex
		)
SELECT s3.concept_code, s4.concept_id, 0 AS q_value, ' ' AS quant_unit, m.qi_combo, m.qd_combo, ' ' AS df_code, ' ' AS bn_code, 0 AS bs,
	' ' AS mf_code, 0 AS r_value, 0 AS quant_unit_id, m.ri_combo, m.rd_combo, 0 AS df_id, 0 AS bn_id, 0 AS mf_id, 'Clinical Drug Comp' AS concept_class_id
FROM (
	-- Collect existing
	SELECT *
	FROM ex
	
	UNION
	
	SELECT DISTINCT c.*,
		FIRST_VALUE(x.ri_combo) OVER (
			PARTITION BY x.qd_combo ORDER BY x.prec
			) AS ri_combo,
		FIRST_VALUE(x.rd_combo) OVER (
			PARTITION BY x.qd_combo ORDER BY x.prec
			) AS rd_combo
	FROM c
	LEFT JOIN x_pattern x ON x.qd_combo = c.qd_combo
	) m
LEFT JOIN (
	SELECT concept_code,
		i_combo AS qi_combo,
		d_combo AS qd_combo
	FROM q_existing
	WHERE quant_value = 0
		AND df_code = ' '
		AND bn_code = ' '
		AND bs = 0
		AND mf_code = ' '
	) AS s3 ON s3.qi_combo = m.qi_combo
	AND s3.qd_combo = m.qd_combo
LEFT JOIN (
	SELECT concept_id,
		i_combo AS ri_combo,
		d_combo AS rd_combo
	FROM r_existing
	WHERE quant_value = 0
		AND df_id = 0
		AND bn_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s4 ON s4.ri_combo = m.ri_combo
	AND s4.rd_combo = m.rd_combo;

-- Create full set of extensions with all attribute (left side of full_corpus)
-- It includes the existing concepts with positive existing concept_id
DROP TABLE IF EXISTS extension_attribute;
CREATE UNLOGGED TABLE extension_attribute AS
SELECT NEXTVAL('extension_id') AS concept_id, e.*
FROM (
	-- make new ones
	SELECT DISTINCT r_value, quant_unit_id, ri_combo, rd_combo, df_id, bn_id, bs, mf_id, concept_class_id
	FROM full_corpus
	WHERE concept_id IS NULL
	ORDER BY r_value, quant_unit_id, ri_combo, rd_combo, df_id, bn_id, bs, mf_id, concept_class_id --just for sequence repeatability
	) e;

-- Add existing
INSERT INTO extension_attribute
SELECT DISTINCT concept_id, r_value, quant_unit_id, ri_combo, rd_combo, df_id, bn_id, bs, mf_id, concept_class_id
FROM full_corpus
WHERE concept_id IS NOT NULL;

-- Connect q_existing concept codes (from drug_concept_stage) to existing corpus or new extensions
DROP TABLE IF EXISTS maps_to;
CREATE UNLOGGED TABLE maps_to AS
SELECT DISTINCT fc.concept_code AS from_code,
	FIRST_VALUE(ea.concept_id) OVER (
		PARTITION BY fc.concept_code ORDER BY q.u_prec
		) AS to_id -- pick only one of many with the better denominator fit
FROM full_corpus fc
JOIN extension_attribute ea ON ea.r_value = fc.r_value
	AND ea.quant_unit_id = fc.quant_unit_id
	AND ea.ri_combo = fc.ri_combo
	AND ea.rd_combo = fc.rd_combo
	AND ea.df_id = fc.df_id
	AND ea.bn_id = fc.bn_id
	AND ea.bs = fc.bs
	AND ea.mf_id = fc.mf_id
LEFT JOIN qr_d_combo q ON q.qd_combo = fc.qd_combo
	AND q.rd_combo = ea.rd_combo
WHERE fc.concept_code IS NOT NULL;

/*******************
* 11. Create names *
*******************/

-- Auto-generate all names 
-- Create RxNorm-style units. UCUM units have no normalized abbreviation
DROP TABLE IF EXISTS rxnorm_unit;
CREATE UNLOGGED TABLE rxnorm_unit (
	rxn_unit VARCHAR(20),
	concept_id int4
	);

INSERT INTO rxnorm_unit VALUES 
 ('ORGANISMS', 45744815), -- Organisms, UCUM calls it {bacteria}
 ('%', 8554),
 ('ACTUAT', 45744809), -- actuation
 ('AU', 45744811), -- allergenic unit
 ('BAU', 45744810), -- bioequivalent allergenic unit
 ('CELLS', 45744812), -- cells
 ('CFU', 9278), -- colony forming unit
 ('CU', 45744813), -- clinical unit
 ('HR', 8505), -- hour
 ('IU', 8718), -- International unit
 ('LFU', 45744814), -- limit of flocculation unit
 ('MCI', 44819154), -- millicurie
 ('MEQ', 9551), -- milliequivalent
 ('MG', 8576), -- milligram
 ('MIN', 9367), -- minim
 ('ML', 8587),
 ('MMOL', 9573),
 ('MU', 9439), -- mega-international unit
 ('PFU', 9379), -- plaque forming unit
 ('PNU', 45744816), -- protein nitrogen unit
 ('SQCM', 9483), -- square centimeter
 ('TCID', 9414), -- 50% tissue culture infectious dose
 ('UNT', 8510), -- unit
 ('IR', 9693), -- index of reactivity
 ('X', 9325), -- Decimal potentiation of homeopathic drugs
 ('C', 9324), -- Centesimal potentation of homoeopathic drugs
 (NULL, 0); -- empty

-- create components
DROP TABLE IF EXISTS spelled_out;
CREATE UNLOGGED TABLE spelled_out AS
	WITH ing_names AS (
			-- translate i_code to ingredient name
			SELECT i.i_code,
				c.concept_name
			FROM ing_stage i
			JOIN concept c ON c.concept_id = i.i_id
			
			UNION
			
			SELECT i.ri_code,
				ds.concept_name
			FROM extension_i i
			JOIN drug_concept_stage ds ON ds.concept_code = i.qi_code
			),
		combo AS (
			-- resolve combos and keep singletons
			SELECT rd_combo,
				rd_combo AS ds_code
			FROM extension_attribute
			WHERE rd_combo NOT LIKE '%-%'
				AND rd_combo <> ' ' -- singletons
			
			UNION
			
			SELECT rd_combo,
				r_ds AS ds_code
			FROM r_breakup -- break up combos
			),
		-- Get all ds
		ds_comp AS (
			SELECT s0.ds_code,
				n.concept_name,
				s0.amount_value + s0.numerator_value AS v, -- one of them is null
				CASE 
					WHEN s0.numerator_unit_concept_id IN (
							8554,
							9325,
							9324
							)
						THEN nu.rxn_unit -- percent and homeopathics 
					WHEN s0.numerator_value <> 0
						THEN CONCAT (
								nu.rxn_unit,
								'/',
								de.rxn_unit
								) -- concentration (liquid)
					ELSE au.rxn_unit -- absolute (solid)
					END AS u
			FROM (
				-- get details on uds in r
				SELECT *
				FROM extension_uds
				
				UNION
				
				SELECT *
				FROM r_uds -- adding them even though they already exist because they might be one of many components
				) AS s0
			JOIN ing_names n ON n.i_code = s0.i_code -- get names
				-- translate units back to RxNorm lingo
			LEFT JOIN rxnorm_unit au ON au.concept_id = s0.amount_unit_concept_id
			LEFT JOIN rxnorm_unit nu ON nu.concept_id = s0.numerator_unit_concept_id
			LEFT JOIN rxnorm_unit de ON de.concept_id = s0.denominator_unit_concept_id
			),
		c_with_combo AS (
			-- combine with combos
			SELECT c.rd_combo,
				d.concept_name,
				d.v,
				d.u
			FROM ds_comp d
			JOIN combo c ON c.ds_code = d.ds_code
			),
		c_builded AS (
			-- build component
			SELECT rd_combo,
				CONCAT (
					concept_name,
					CASE 
						WHEN v IS NULL
							THEN NULL
						ELSE CONCAT (
								' ' || TRIM(TRAILING '.' FROM TO_CHAR(v, 'FM9999999999999999999990.999999999999999999999')),
								' ',
								u
								)
						END
					) AS comp_name
			FROM c_with_combo
			)
-- build the component
SELECT c.concept_id,
	CASE 
		WHEN c.r_value = 0
			THEN NULL
		ELSE CONCAT (
				c.r_value,
				' ',
				CONCAT (
					FIRST_VALUE(q.rxn_unit) OVER (
						PARTITION BY c.concept_id,
						/*
						We need emulate "ignore nulls" option in FIRST_VALUE, bug PG doesn't support it. So we use a "virtual" partition
						Note: this works ONLY for default windowing clause (UNBOUNDED PRECEDING and current row)
						*/
						(
							CASE 
								WHEN q.rxn_unit IS NULL
									THEN 0
								ELSE 1
								END
							) ORDER BY comp.comp_name
						),
					' '
					)
				)
		END AS quant,
	comp.comp_name,
	SUM(comp.comp_len) OVER (
		PARTITION BY c.concept_id ORDER BY comp.comp_name ROWS BETWEEN UNBOUNDED PRECEDING
				AND CURRENT ROW
		) AS agg_len,
	CASE 
		WHEN c.df_id = 0
			THEN NULL
		ELSE ' '|| COALESCE(edf.concept_name, df.concept_name)
		END AS df_name,
	CASE 
		WHEN c.bn_id = 0
			THEN NULL
		ELSE ' [' || COALESCE(ebn.concept_name, bn.concept_name) || ']'
		END AS bn_name,
	' Box of ' || NULLIF (c.bs,0) AS box,
	CASE 
		WHEN c.mf_id = 0
			THEN NULL
				-- remove stop words
		ELSE ' by ' || REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(COALESCE(emf.concept_name, mf.concept_name), ' Ltd', ''), ' Plc', ''), ' UK', ''), ' (UK)', ''), ' Pharmaceuticals', ''), ' Pharma', ''), ' GmbH', ''), 'Laboratories', '')
			--  else ' by '||regexp_replace(nvl(emf.concept_name, mf.concept_name), ' Inc\.?| Ltd\.?| Plc| PLC| UK| \(UK\)| \(U\.K\.\)| Canada| Pharmaceuticals| Pharma| GmbH| Laboratories') -- XXXX use this going forward 
		END AS mf_name
FROM extension_attribute c
JOIN (
	-- resolve the rd_combo to uds details
	SELECT rd_combo,
		comp_name,
		LENGTH(comp_name) + 3 AS comp_len -- length plus 3 characters for ' / '
	FROM c_builded
	) comp ON comp.rd_combo = c.rd_combo
-- get quant unit in RxNorm notation
LEFT JOIN rxnorm_unit q ON q.concept_id = c.quant_unit_id
-- get dose form from Rx or source
LEFT JOIN extension_df edf ON edf.df_id = c.df_id
LEFT JOIN concept df ON df.concept_id = c.df_id
-- get brand name from Rx or source
LEFT JOIN extension_bn ebn ON ebn.bn_id = c.bn_id
LEFT JOIN concept bn ON bn.concept_id = c.bn_id
-- get supplier
LEFT JOIN extension_mf emf ON emf.mf_id = c.mf_id
LEFT JOIN concept mf ON mf.concept_id = c.mf_id
WHERE c.concept_id < 0
	AND c.rd_combo <> ' ';-- Exclude Drug Forms, do these in the next step

-- Add Drug Forms
INSERT INTO spelled_out
WITH ing_names AS (
		-- translate i_code to ingredient name
		SELECT i.i_code,
			c.concept_name
		FROM ing_stage i
		JOIN concept c ON c.concept_id = i.i_id
		
		UNION
		
		SELECT i.ri_code,
			ds.concept_name
		FROM extension_i i
		JOIN drug_concept_stage ds ON ds.concept_code = i.qi_code
		),
	-- Get all i_combos
	u AS (
		SELECT i_combo AS ri_combo,
			concept_name AS comp_name
		FROM (
			-- get combo to i_code resolution
			SELECT ri_combo AS i_combo,
				TRIM(UNNEST(REGEXP_MATCHES(s0.ri_combo, '[^-]+', 'g'))) AS i_code
			FROM (
				SELECT DISTINCT ri_combo
				FROM extension_attribute
				WHERE concept_id < 0
				) AS s0
			) AS s1
		JOIN ing_names n ON n.i_code = s1.i_code -- get name
		)
-- build the component
SELECT c.concept_id,
	NULL AS quant,
	comp.comp_name,
	SUM(comp.comp_len) OVER (
		PARTITION BY c.concept_id ORDER BY comp.comp_name ROWS BETWEEN UNBOUNDED PRECEDING
				AND CURRENT ROW
		) AS agg_len,
	CASE 
		WHEN c.df_id = 0
			THEN NULL
		ELSE CONCAT (
				' ',
				COALESCE(edf.concept_name, df.concept_name)
				)
		END AS df_name,
	CASE 
		WHEN c.bn_id = 0
			THEN NULL
		ELSE CONCAT (
				' [',
				COALESCE(ebn.concept_name, bn.concept_name),
				']'
				)
		END AS bn_name,
	NULL AS box,
	NULL AS mf_name
FROM extension_attribute c
JOIN (
	SELECT ri_combo,
		comp_name,
		LENGTH(comp_name) + 3 AS comp_len -- length plus 3 characters for ' / '
	FROM u
	) comp ON comp.ri_combo = c.ri_combo
-- get dose form from Rx or source
LEFT JOIN extension_df edf ON edf.df_id = c.df_id
LEFT JOIN concept df ON df.concept_id = c.df_id
-- get brand name from Rx or source
LEFT JOIN extension_bn ebn ON ebn.bn_id = c.bn_id
LEFT JOIN concept bn ON bn.concept_id = c.bn_id
-- get supplier
WHERE c.concept_id < 0
	AND c.rd_combo = ' ';-- Only Drug Forms

DROP TABLE IF EXISTS extension_name;
CREATE UNLOGGED TABLE extension_name (
	concept_id int4,
	concept_name VARCHAR(255)
	);
-- Create names 
INSERT INTO extension_name
SELECT s0.concept_id,
	-- count the cumulative length of the components. The tildas are to make sure the three dots are put at the end of the list
	SUBSTR(REPLACE(CONCAT (
				s0.quant,
				STRING_AGG(s0.comp_name, ' / ' ORDER BY UPPER(s0.comp_name) COLLATE "C"),
				s0.df_name,
				s0.bn_name,
				s0.box,
				s0.mf_name
				), '~~~', '...'), 1, 255) AS concept_name
FROM (
	-- keep only components where concatenation will leave enough space for the quant, dose form, brand name and box size
	SELECT *
	FROM spelled_out s
	WHERE s.agg_len <= 253 - (COALESCE(LENGTH(s.quant), 0) + COALESCE(LENGTH(s.df_name), 0) + COALESCE(LENGTH(s.bn_name), 0) + COALESCE(LENGTH(s.box), 0) + COALESCE(LENGTH(s.mf_name), 0) + 3)
	-- Add three dots if ingredients are to be cut
	
	UNION ALL
	
	SELECT DISTINCT s.concept_id,
		s.quant,
		'~~~' AS comp_name, -- last ASCII character to make sure they get sorted towards the end.
		1 AS agg_len,
		s.df_name,
		s.bn_name,
		s.box,
		s.mf_name
	FROM spelled_out s
	WHERE s.agg_len > 253 - (COALESCE(LENGTH(s.quant), 0) + COALESCE(LENGTH(s.df_name), 0) + COALESCE(LENGTH(s.bn_name), 0) + COALESCE(LENGTH(s.box), 0) + COALESCE(LENGTH(s.mf_name), 0) + 6)
	) AS s0
GROUP BY s0.quant,
	s0.concept_id,
	s0.df_name,
	s0.bn_name,
	s0.box,
	s0.mf_name;

/********************
* 12. Process Packs *
********************/

-- create a complete set of packs with attributes
-- If the components are given as anything more granular than Clinical Drug or Quant Clinical Drug, strip those attributes. Brand Name and Supplier are only at the pack level
DROP TABLE IF EXISTS q_existing_pack;
CREATE UNLOGGED TABLE q_existing_pack AS
	WITH component AS (
			-- Clip all component attributes but df_id and quant, making them (Quant) Clinical Drugs. Brand Names and Suppliers should sit with the Pack, and Box Size is irrelevant in a compnent because a duplication of amount
			SELECT s0.drug_concept_code,
				ac.concept_id
			FROM (
				SELECT DISTINCT drug_concept_code
				FROM pc_stage
				) AS s0 -- get list of components
			JOIN maps_to mo ON mo.from_code = s0.drug_concept_code -- get their concept_id
			JOIN extension_attribute ao ON ao.concept_id = mo.to_id -- get full attribute set in r
			JOIN (
				SELECT DISTINCT concept_id,
					r_value,
					quant_unit_id,
					rd_combo,
					df_id
				FROM extension_attribute
				WHERE rd_combo <> ' '
					AND bn_id = 0
					AND bs = 0
					AND mf_id = 0
				) ac ON ac.r_value = ao.r_value
				AND ac.quant_unit_id = ao.quant_unit_id
				AND ac.rd_combo = ao.rd_combo
				AND ac.df_id = ao.df_id -- Get the Clinical equivalent
			)
SELECT DISTINCT -- because the content in some packs, albeit different in drug_concept_stage, becomes identical after mapping
	pc.pack_concept_code,
	STRING_AGG(CONCAT (
			COALESCE(pc.amount, 0),
			'/',
			c.concept_id
			), ';' ORDER BY c.concept_id) AS components,
	COUNT(*) AS cnt,
	MAX(COALESCE(q_bn.bn_id, 0)) AS bn_id,
	MAX(COALESCE(pc.box_size, 0)) AS bs,
	MAX(COALESCE(q_mf.mf_id, 0)) AS mf_id,
	MAX(CASE 
			WHEN q_mf.mf_id IS NOT NULL
				THEN 'Marketed Product'
			WHEN pc.box_size IS NOT NULL
				AND q_bn.bn_id IS NOT NULL
				THEN 'Branded Pack Box'
			WHEN pc.box_size IS NOT NULL
				THEN 'Clinical Pack Box'
			WHEN q_bn.bn_id IS NOT NULL
				THEN 'Branded Pack'
			ELSE 'Clinical Pack'
			END) AS concept_class_id
FROM pc_stage pc
-- Component drug
JOIN component c ON c.drug_concept_code = pc.drug_concept_code
LEFT JOIN (
	-- Obtain Brand Name if exists, could be more than one effective r_to_c
	SELECT DISTINCT q.concept_code,
		COALESCE(x.bn_id, ex.bn_id) AS bn_id
	FROM q_bn q
	LEFT JOIN x_bn x ON x.bn_code = q.bn_code
	LEFT JOIN extension_bn ex ON ex.bn_code = q.bn_code
	) q_bn ON q_bn.concept_code = pc.pack_concept_code
LEFT JOIN (
	-- Obtain Supplier if exists, could be more than one effective r_to_c
	SELECT DISTINCT q.concept_code,
		COALESCE(x.mf_id, ex.mf_id) AS mf_id
	FROM q_mf q
	LEFT JOIN x_mf x ON x.mf_code = q.mf_code
	LEFT JOIN extension_mf ex ON ex.mf_code = q.mf_code
	) q_mf ON q_mf.concept_code = pc.pack_concept_code
GROUP BY pc.pack_concept_code;

DROP TABLE IF EXISTS r_existing_pack;
CREATE UNLOGGED TABLE r_existing_pack AS
SELECT s0.pack_concept_id,
	STRING_AGG(CONCAT (
			s0.amount,
			'/',
			s0.drug_concept_id
			), ';' ORDER BY s0.drug_concept_id) AS components,
	COUNT(*) AS cnt,
	s0.bn_id,
	s0.bs,
	s0.mf_id
FROM (
	SELECT pc.pack_concept_id,
		pc.drug_concept_id,
		COALESCE(pc.amount, 0) AS amount,
		COALESCE(pc.box_size, 0) AS bs,
		COALESCE(rb.bn_id, 0) AS bn_id,
		COALESCE(mf_id, 0) AS mf_id
	FROM pack_content pc
	LEFT JOIN r_bn rb ON rb.concept_id = pc.pack_concept_id
	LEFT JOIN r_mf rm ON rm.concept_id = pc.pack_concept_id
	JOIN concept c ON c.concept_id = pc.pack_concept_id
		AND c.vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
	) AS s0
GROUP BY s0.pack_concept_id,
	s0.bn_id,
	s0.bs,
	s0.mf_id;

-- XXXX Remove Branded Packs that have no Brand Name. This will no longer be needed when RxNorm starts adding Brand Names for Packs
DELETE
FROM r_existing_pack r
WHERE EXISTS (
		SELECT 1
		FROM concept c
		WHERE c.concept_id = r.pack_concept_id
			AND c.concept_class_id = 'Branded Pack'
		)
	AND r.bn_id = 0;

-- Create pack hierarchy
DROP TABLE IF EXISTS full_pack;
CREATE UNLOGGED TABLE full_pack AS
SELECT q.pack_concept_code AS q_concept_code,
	r.pack_concept_id AS r_concept_id,
	q.components,
	q.cnt,
	q.bn_id,
	q.bs,
	q.mf_id,
	q.concept_class_id
FROM (
	-- get distinct content of q_existing_pack
	SELECT DISTINCT pack_concept_code,
		components,
		cnt,
		bn_id,
		bs,
		mf_id,
		concept_class_id
	FROM q_existing_pack
	WHERE concept_class_id = 'Marketed Product'
	) q
LEFT JOIN r_existing_pack r ON r.components = q.components
	AND r.cnt = q.cnt
	AND r.bn_id = q.bn_id
	AND r.bs = q.bs
	AND r.mf_id = q.mf_id;

-- Branded Pack Box. Definition: bn and bs, but no mf.
INSERT INTO full_pack
SELECT s1.pack_concept_code AS q_concept_code, s2.pack_concept_id AS r_concept_id, s0.components, s0.cnt, s0.bn_id, s0.bs, 0 AS mf_id, 'Branded Pack Box' AS concept_class_id
FROM (
	-- get those we already have
	SELECT components, cnt, bn_id, bs
	FROM full_pack
	WHERE bn_id <> 0
		AND bs <> 0
	
	UNION -- add more from q
	
	SELECT components, cnt, bn_id, bs
	FROM q_existing_pack
	WHERE bn_id <> 0
		AND bs <> 0
		AND mf_id = 0
	) AS s0
LEFT JOIN (
	SELECT pack_concept_code, components, cnt, bn_id, bs
	FROM q_existing_pack
	WHERE mf_id = 0
	) AS s1 ON s1.components = s0.components
	AND s1.cnt = s0.cnt
	AND s1.bn_id = s0.bn_id
	AND s1.bs = s0.bs
LEFT JOIN (
	SELECT pack_concept_id, components, cnt, bn_id, bs
	FROM r_existing_pack
	WHERE mf_id = 0
	) AS s2 ON s2.components = s0.components
	AND s2.cnt = s0.cnt
	AND s2.bn_id = s0.bn_id
	AND s2.bs = s0.bs;

-- Branded Pack. Definition: bn, but no bs or mf.
INSERT INTO full_pack
SELECT s1.pack_concept_code AS q_concept_code, s2.pack_concept_id AS r_concept_id, s0.components, s0.cnt, s0.bn_id, 0 AS bs, 0 AS mf_id, 'Branded Pack' AS concept_class_id
FROM (
	SELECT components, cnt, bn_id
	FROM full_pack
	WHERE bn_id <> 0
	
	UNION
	
	SELECT components, cnt, bn_id
	FROM q_existing_pack
	WHERE bn_id <> 0
		AND bs = 0
		AND mf_id = 0
	) AS s0
LEFT JOIN (
	SELECT pack_concept_code, components, cnt, bn_id
	FROM q_existing_pack
	WHERE bs = 0
		AND mf_id = 0
	) AS s1 ON s1.components = s0.components
	AND s1.cnt = s0.cnt
	AND s1.bn_id = s0.bn_id
LEFT JOIN (
	SELECT pack_concept_id, components, cnt, bn_id
	FROM r_existing_pack
	WHERE bs = 0
		AND mf_id = 0
	) AS s2 ON s2.components = s0.components
	AND s2.cnt = s0.cnt
	AND s2.bn_id = s0.bn_id;

-- Clinical Pack Box. Definition: bs, but no bn or mf.
INSERT INTO full_pack
SELECT s1.pack_concept_code AS q_concept_code, s2.pack_concept_id AS r_concept_id, s0.components, s0.cnt, 0 AS bn_id, s0.bs, 0 AS mf_id, 'Clinical Pack Box' AS concept_class_id
FROM (
	SELECT components, cnt, bs
	FROM full_pack
	WHERE bs <> 0
	
	UNION
	
	SELECT components, cnt, bs
	FROM q_existing_pack
	WHERE bs <> 0
		AND bn_id = 0
		AND mf_id = 0
	) AS s0
LEFT JOIN (
	SELECT pack_concept_code, components, cnt, bs
	FROM q_existing_pack
	WHERE bn_id = 0
		AND mf_id = 0
	) AS s1 ON s1.components = s0.components
	AND s1.cnt = s0.cnt
	AND s1.bs = s0.bs
LEFT JOIN (
	SELECT pack_concept_id, components, cnt, bs
	FROM r_existing_pack
	WHERE bn_id = 0
		AND mf_id = 0
	) AS s2 ON s2.components = s0.components
	AND s2.cnt = s0.cnt
	AND s2.bs = s0.bs;

-- Clinical Pack. Definition: neither bn, bs nor mf.
INSERT INTO full_pack
SELECT s1.pack_concept_code AS q_concept_code, s2.pack_concept_id AS r_concept_id, s0.components, s0.cnt, 0 AS bn_id, 0 AS bs, 0 AS mf_id, 'Clinical Pack' AS concept_class_id
FROM (
	SELECT components, cnt
	FROM full_pack
	
	UNION
	
	SELECT components, cnt
	FROM q_existing_pack
	WHERE bn_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s0
LEFT JOIN (
	SELECT pack_concept_code, components, cnt
	FROM q_existing_pack
	WHERE bn_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s1 ON s1.components = s0.components
	AND s1.cnt = s0.cnt
LEFT JOIN (
	SELECT pack_concept_id, components, cnt
	FROM r_existing_pack
	WHERE bn_id = 0
		AND bs = 0
		AND mf_id = 0
	) AS s2 ON s2.components = s0.components
	AND s2.cnt = s0.cnt;

-- Create a distinct set, since q may contain duplicates. R shouldn't, but doesn't hurt kicking them out, too
DROP TABLE IF EXISTS pack_attribute;
CREATE UNLOGGED TABLE pack_attribute AS
SELECT NEXTVAL('extension_id') AS concept_id, fp.*
FROM (
	SELECT DISTINCT components, cnt, bn_id, bs, mf_id, concept_class_id
	FROM full_pack
	WHERE r_concept_id IS NULL
	) fp
ORDER BY fp.components, fp.cnt, fp.bn_id, fp.bs, fp.mf_id, fp.concept_class_id;--just for sequence repeatability

-- Create names for each pack in pack_attribute
DROP TABLE IF EXISTS pack_name;
CREATE UNLOGGED TABLE pack_name AS
	-- Get the component parts
	WITH comp_parts AS (
			SELECT cp.concept_id,
				ROW_NUMBER() OVER (
					PARTITION BY cp.concept_id ORDER BY LOWER(COALESCE(cr.concept_name, en.concept_name))
					) AS c_order,
				CONCAT (
					CASE 
						WHEN cp.amount = 0
							THEN NULL
						ELSE CONCAT (
								cp.amount,
								' '
								)
						END,
					CONCAT (
						'(',
						COALESCE(cr.concept_name, en.concept_name)
						)
					) AS content_name,
				CASE 
					WHEN cp.amount = 0
						THEN 0
					ELSE LENGTH(cp.amount::VARCHAR) + 1
					END AS a_len, -- length of the amount
				LENGTH(COALESCE(cr.concept_name, en.concept_name)) AS n_len -- length of the concept_name
			FROM (
				-- break up component into amount and drug
				SELECT s0.concept_id,
					s0.component,
					SUBSTR(s0.component, 1, devv5.instr(s0.component, '/', 1) - 1)::INT AS amount,
					SUBSTR(s0.component, devv5.instr(s0.component, '/', 1) + 1)::INT AS drug_concept_id
				FROM (
					-- break up the components string
					SELECT concept_id,
						TRIM(UNNEST(REGEXP_MATCHES(components, '[^;]+', 'g'))) AS component
					FROM pack_attribute
					) AS s0
				) cp
			LEFT JOIN concept cr ON cr.concept_id = cp.drug_concept_id
			LEFT JOIN extension_name en ON en.concept_id = cp.drug_concept_id
			),
		-- Get the common part
		common_part AS (
			SELECT DISTINCT cp.concept_id,
				CASE 
					WHEN cp.bn_id = 0
						THEN NULL
					ELSE ' [' || COALESCE(bn.concept_name, ebn.concept_name) || ']'
					END AS bn_name,
				' box of ' || NULLIF (cp.bs,0) AS bs_name,
				CASE 
					WHEN cp.mf_id = 0
						THEN NULL
					ELSE ' by ' || COALESCE(mf.concept_name, emf.concept_name)
					END AS mf_name
			-- case when cp.mf_id=0 then null else ' by '||regexp_replace(COALESCE(mf.concept_name, emf.concept_name), ' Inc\.?| Ltd| Plc| PLC| UK| \(UK\)| \(U\.K\.\)| Canada| Pharmaceuticals| Pharma| GmbH| Laboratories') end as mf_name
			FROM pack_attribute cp
			LEFT JOIN concept bn ON bn.concept_id = cp.bn_id
			LEFT JOIN extension_bn ebn ON ebn.bn_id = cp.bn_id
			LEFT JOIN concept mf ON mf.concept_id = cp.mf_id
			LEFT JOIN extension_mf emf ON emf.mf_id = cp.mf_id
			),
		-- Calculate total length of everything if space weren't the issue, and then calculate the factor that each concept_name needs to be shortened by
		common_part2 AS (
			SELECT pd.concept_id,
				CONCAT (
					pd.bn_name,
					pd.bs_name,
					pd.mf_name
					) AS concept_name,
				COALESCE(LENGTH(pd.bs_name), 0) + COALESCE(LENGTH(pd.bn_name), 0) + COALESCE(LENGTH(pd.mf_name), 0) AS len -- length of the brand name the Pack plus extra characters making up the name minus the ' / ' at the last component
			FROM common_part pd
			),
		common_part3 AS (
			SELECT s1.concept_id,
				(245 - s1.all_a_len - p.len) / s1.all_n_len::NUMERIC AS factor -- 255-10 for common pack text (curly brackets, spaces)
			FROM (
				SELECT DISTINCT concept_id,
					SUM(n_len) OVER (PARTITION BY concept_id) AS all_n_len, -- 7: slashes, parentheses and spaces, minus the trailing ' / '
					SUM(a_len + 5) OVER (PARTITION BY concept_id) - 3 AS all_a_len -- 7: slashes, parentheses and spaces, minus the trailing ' / '
				FROM comp_parts c
				) AS s1
			JOIN common_part2 p ON p.concept_id = s1.concept_id
			),
		-- Cut the individual components by the factor and add ...
		cutted AS (
			SELECT l.concept_id,
				c.c_order,
				CASE 
					WHEN l.factor < 1
						THEN CONCAT (
								SUBSTR(c.content_name, 1, GREATEST((c.n_len * l.factor)::INT - 3, 0)),
								'...'
								)
					ELSE c.content_name
					END AS concept_name
			FROM common_part3 l
			JOIN comp_parts c ON c.concept_id = l.concept_id
			)
SELECT c_p.concept_id,
	CONCAT (
		'{',
		STRING_AGG(c_p.concept_name, ') / ' ORDER BY c_p.c_order),
		') } Pack',
		p.concept_name
		) AS concept_name
FROM cutted c_p -- components, possibly trimmed
JOIN common_part2 p ON p.concept_id = c_p.concept_id -- common part
GROUP BY c_p.concept_id,
	p.concept_name;-- aggregate within concept_code


/*****************************
* 13. Write RxNorm Extension *
*****************************/

-- Create sequence that starts after existing OMOPxxx-style concept codes
DO $$
DECLARE
	ex INTEGER;
BEGIN
	SELECT MAX(REPLACE(concept_code, 'OMOP','')::int4)+1 INTO ex FROM (
		SELECT concept_code FROM concept WHERE concept_code LIKE 'OMOP%'  AND concept_code NOT LIKE '% %' -- Last valid value of the OMOP123-type codes
		UNION ALL
		SELECT concept_code FROM drug_concept_stage WHERE concept_code LIKE 'OMOP%' AND concept_code NOT LIKE '% %' -- Last valid value of the OMOP123-type codes
	) AS s0;
	DROP SEQUENCE IF EXISTS omop_seq;
	EXECUTE 'CREATE SEQUENCE omop_seq INCREMENT BY 1 START WITH ' || ex || ' NO CYCLE CACHE 20';
END$$;

-- Empty concept_stage in case there are remnants from a previous run.
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE drug_strength_stage;
TRUNCATE TABLE pack_content_stage;

-- Write Ingredients that have no equivalent. Ingredients are written in code notation. Therefore, concept_id is null, and the XXX code is in concept_code
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT 0 AS concept_id,
	dcs.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	'Ingredient' AS concept_class_id,
	'S' AS standard_concept,
	i.ri_code AS concept_code, -- XXX code, rather than original from dcs. Will be replaced with OMOPxxx-style concept_code
	COALESCE(dcs.valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = dcs.vocabulary_id
			)) AS valid_start_date,
	COALESCE(dcs.valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	NULL AS invalid_reason
FROM extension_i i
JOIN drug_concept_stage dcs ON dcs.concept_code = i.qi_code;

-- Write Dose Forms that have no equivalent. Dose forms have negative ids
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT df.df_id AS concept_id, -- will be replaced with null after writing all relationships
	dcs.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	'Dose Form' AS concept_class_id,
	NULL AS standard_concept,
	'OMOP' || NEXTVAL('omop_seq') AS concept_code,
	COALESCE(dcs.valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = dcs.vocabulary_id
			)) AS valid_start_date,
	COALESCE(dcs.valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	NULL AS invalid_reason
FROM extension_df df
JOIN drug_concept_stage dcs ON dcs.concept_code = df.df_code;

-- Write Brand Name that have no equivalent
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT bn.bn_id AS concept_id, -- will be replaced with null after writing all relationships
	dcs.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	'Brand Name' AS concept_class_id,
	NULL AS standard_concept,
	'OMOP' || NEXTVAL('omop_seq') AS concept_code,
	COALESCE(dcs.valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = dcs.vocabulary_id
			)) AS valid_start_date,
	COALESCE(dcs.valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	NULL AS invalid_reason
FROM extension_bn bn
JOIN drug_concept_stage dcs ON dcs.concept_code = bn.bn_code;

-- Write Supplier that have no equivalent
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT mf.mf_id AS concept_id, -- will be replaced with null after writing all relationships
	dcs.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	'Supplier' AS concept_class_id,
	NULL AS standard_concept,
	'OMOP' || NEXTVAL('omop_seq') AS concept_code,
	COALESCE(dcs.valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = dcs.vocabulary_id
			)) AS valid_start_date,
	COALESCE(dcs.valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	NULL AS invalid_reason
FROM extension_mf mf
JOIN drug_concept_stage dcs ON dcs.concept_code = mf.mf_code;

-- Write drug concepts from extension_attribute
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT ea.concept_id,
	en.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	ea.concept_class_id,
	'S' AS standard_concept, -- Standard Concept 
	'OMOP' || NEXTVAL('omop_seq') AS concept_code,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM extension_attribute ea
JOIN extension_name en ON en.concept_id = ea.concept_id;-- limits it to only negative (new) concept_ids

-- write RxNorm-like relationships between concepts of all classes except Drug Forms and Clinical Drug Component based on matching components
DROP TABLE IF EXISTS rl;
CREATE UNLOGGED TABLE rl (
	concept_class_1 VARCHAR(20),
	relationship_id VARCHAR(20),
	concept_class_2 VARCHAR(20)
	);

INSERT INTO rl VALUES
('Brand Name', 'Brand name of', 'Branded Drug Box'),
('Brand Name', 'Brand name of', 'Branded Drug Comp'),
('Brand Name', 'Brand name of', 'Branded Drug Form'),
('Brand Name', 'Brand name of', 'Branded Drug'),
('Brand Name', 'Brand name of', 'Branded Pack'),
('Brand Name', 'Brand name of', 'Branded Pack Box'),
('Brand Name', 'Brand name of', 'Marketed Product'),
('Brand Name', 'Brand name of', 'Quant Branded Box'),
('Brand Name', 'Brand name of', 'Quant Branded Drug'),
('Branded Drug Box', 'Has marketed form', 'Marketed Product'),
('Branded Drug Box', 'Has quantified form', 'Quant Branded Box'),
('Branded Drug Comp', 'Constitutes', 'Branded Drug'),
('Branded Drug Form', 'RxNorm inverse is a', 'Branded Drug'),
('Branded Drug', 'Available as box', 'Branded Drug Box'),
('Branded Drug', 'Has marketed form', 'Marketed Product'),
('Branded Drug', 'Has quantified form', 'Quant Branded Drug'),
('Branded Pack', 'Has marketed form', 'Marketed Product'),
('Branded Pack', 'Available as box', 'Branded Pack Box'),
('Clinical Drug Box', 'Has marketed form', 'Marketed Product'),
('Clinical Drug Box', 'Has quantified form', 'Quant Clinical Box'),
('Clinical Drug Box', 'Has tradename', 'Branded Drug Box'),
('Clinical Drug Comp', 'Constitutes', 'Clinical Drug'),
('Clinical Drug Comp', 'Has tradename', 'Branded Drug Comp'),
('Clinical Drug Form', 'Has tradename', 'Branded Drug Form'),
('Clinical Drug Form', 'RxNorm inverse is a', 'Clinical Drug'),
('Clinical Drug', 'Available as box', 'Clinical Drug Box'),
('Clinical Drug', 'Has marketed form', 'Marketed Product'),
('Clinical Drug', 'Has quantified form', 'Quant Clinical Drug'),
('Clinical Drug', 'Has tradename', 'Branded Drug'),
('Clinical Pack', 'Has marketed form', 'Marketed Product'),
('Clinical Pack', 'Has tradename', 'Branded Pack'),
('Clinical Pack', 'Available as box', 'Clinical Pack Box'),
('Clinical Pack Box', 'Has tradename', 'Branded Pack Box'),
('Dose Form', 'RxNorm dose form of', 'Branded Drug Box'),
('Dose Form', 'RxNorm dose form of', 'Branded Drug Form'),
('Dose Form', 'RxNorm dose form of', 'Branded Drug'),
('Dose Form', 'RxNorm dose form of', 'Branded Pack'),
('Dose Form', 'RxNorm dose form of', 'Clinical Drug Box'),
('Dose Form', 'RxNorm dose form of', 'Clinical Drug Form'),
('Dose Form', 'RxNorm dose form of', 'Clinical Drug'),
('Dose Form', 'RxNorm dose form of', 'Clinical Pack'),
('Dose Form', 'RxNorm dose form of', 'Marketed Product'),
('Dose Form', 'RxNorm dose form of', 'Quant Branded Box'),
('Dose Form', 'RxNorm dose form of', 'Quant Branded Drug'),
('Dose Form', 'RxNorm dose form of', 'Quant Clinical Box'),
('Dose Form', 'RxNorm dose form of', 'Quant Clinical Drug'),
('Ingredient', 'Has brand name', 'Brand Name'),
('Ingredient', 'RxNorm ing of', 'Clinical Drug Comp'),
('Ingredient', 'RxNorm ing of', 'Clinical Drug Form'),
('Marketed Product', 'Has Supplier', 'Supplier'),
('Supplier', 'Supplier of', 'Marketed Product'),
('Quant Branded Box', 'Has marketed form', 'Marketed Product'),
('Quant Branded Drug', 'Available as box', 'Quant Branded Box'),
('Quant Branded Drug', 'Has marketed form', 'Marketed Product'),
('Quant Clinical Box', 'Has marketed form', 'Marketed Product'),
('Quant Clinical Box', 'Has tradename', 'Quant Branded Box'),
('Quant Clinical Drug', 'Available as box', 'Quant Clinical Box'),
('Quant Clinical Drug', 'Has marketed form', 'Marketed Product'),
('Quant Clinical Drug', 'Has tradename', 'Quant Branded Drug');

-- Create ea in both concept_id and concept_code/vocabulary_id notation
DROP TABLE IF EXISTS ex;
CREATE UNLOGGED TABLE ex AS -- create extension_attribute in concept_code/vocabulary_id notation
SELECT COALESCE(c.concept_code, cs.concept_code) AS concept_code,
	COALESCE(c.vocabulary_id, cs.vocabulary_id) AS vocabulary_id,
	ea.concept_id, ea.r_value, ea.quant_unit_id, ea.ri_combo, ea.rd_combo, ea.df_id, ea.bn_id, ea.bs, ea.mf_id, ea.concept_class_id
FROM extension_attribute ea
LEFT JOIN concept c ON c.concept_id = ea.concept_id
LEFT JOIN concept_stage cs ON cs.concept_id = ea.concept_id;

-- Write inner-RxNorm Extension relationships, mimicking RxNorm
-- Everything but the Drug Forms, Clinical Drug Comp and Marketed Products
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT -- because several of them can map to the same existing RxE creating duplicates
	an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage limit 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_2 = de.concept_class_id
	AND r.concept_class_1 NOT IN (
		'Clinical Drug Form',
		'Branded Drug Form',
		'Clinical Drug Comp'
		) -- these have no valid d_combo, or the d_combo has to be decomposed
JOIN ex an ON an.concept_class_id = r.concept_class_1
	AND an.rd_combo = de.rd_combo -- the d_combos have to match completely
	AND de.r_value = CASE an.r_value
		WHEN 0
			THEN de.r_value
		ELSE an.r_value
		END -- the descendant may not have quants
	AND de.quant_unit_id = CASE an.quant_unit_id
		WHEN 0
			THEN de.quant_unit_id
		ELSE an.quant_unit_id
		END
	AND de.df_id = CASE an.df_id
		WHEN 0
			THEN de.df_id
		ELSE an.df_id
		END -- the descedant may not have a df
	AND de.bn_id = CASE an.bn_id
		WHEN 0
			THEN de.bn_id
		ELSE an.bn_id
		END -- the descendant may not have a bn
	AND de.bs = CASE an.bs
		WHEN 0
			THEN de.bs
		ELSE an.bs
		END -- the descendant may not have bs
	AND de.concept_id <> an.concept_id -- to avoid linking to self
WHERE de.concept_class_id NOT IN (
		'Clinical Drug Comp',
		'Clinical Drug Form',
		'Clinical Drug',
		'Branded Drug Form',
		'Marketed Product'
		)
	AND de.concept_id < 0; -- descendant has to be a new extension, otherwise we are writing existing relationships

-- Marketed Products: Everything has to agree except Supplier. There are not links amongst Marketed Product, everything links up to the next level
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_2 = de.concept_class_id
	AND r.concept_class_1 <> 'Marketed Product' -- need to exclude otherwise it's linking Marketed to Marketed, which are not defined
JOIN ex an ON an.concept_class_id = r.concept_class_1
	AND an.rd_combo = de.rd_combo -- the d_combos have to match completely
	AND de.r_value = CASE an.r_value
		WHEN 0
			THEN de.r_value
		ELSE an.r_value
		END -- the descendant may not have quants
	AND de.quant_unit_id = CASE an.quant_unit_id
		WHEN 0
			THEN de.quant_unit_id
		ELSE an.quant_unit_id
		END
	AND de.df_id = CASE an.df_id
		WHEN 0
			THEN de.df_id
		ELSE an.df_id
		END -- the descedant may not have a df
	AND de.bn_id = CASE an.bn_id
		WHEN 0
			THEN de.bn_id
		ELSE an.bn_id
		END -- the descendant may not have a bn
	AND de.bs = CASE an.bs
		WHEN 0
			THEN de.bs
		ELSE an.bs
		END -- the descendant may not have bs
	AND de.concept_id <> an.concept_id -- to avoid linking to self
WHERE de.concept_class_id = 'Marketed Product'
	AND de.concept_id < 0;-- descendant has to be a new extension, otherwise we are writing existing relationships

-- Drug Forms
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_2 = de.concept_class_id
	AND r.concept_class_1 IN (
		'Clinical Drug Form',
		'Branded Drug Form'
		) -- these have i_combo to share with their descendants
JOIN ex an ON an.concept_class_id = r.concept_class_1
	AND an.ri_combo = de.ri_combo -- the i_combos have to match completely
	AND de.df_id = CASE an.df_id
		WHEN 0
			THEN de.df_id
		ELSE an.df_id
		END -- the descedant may not have a df
	AND de.bn_id = CASE an.bn_id
		WHEN 0
			THEN de.bn_id
		ELSE an.bn_id
		END -- the descendant may not have a bn
	AND de.concept_id <> an.concept_id -- to avoid linking to self
WHERE de.concept_id < 0;-- descendant has to be a new extension, otherwise we are writing existing relationships

-- Clinical Drug Comp - ds_combo is really only singleton q_ds and needs be decomposed
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	-- Create de that has ds_code instead of d_combo by splitting them up
	SELECT COALESCE(s0.r_ds, e.rd_combo) AS r_ds, -- component ds from rd_combo
		e.concept_code, e.vocabulary_id, e.concept_id, e.r_value, e.quant_unit_id, e.rd_combo, e.df_id, e.bn_id, e.bs, e.mf_id, e.concept_class_id
	FROM ex e
	JOIN (
		SELECT rd_combo,
			rd_combo AS r_ds
		FROM extension_attribute
		WHERE rd_combo NOT LIKE '%-%'
			AND rd_combo <> ' ' -- singletons
		
		UNION
		
		SELECT rd_combo,
			r_ds AS ds_code
		FROM r_breakup -- break up combos
		) AS s0 ON s0.rd_combo = e.rd_combo -- singleton misses singletons that are not in combos. They never get added.
	WHERE e.concept_class_id IN (
			'Clinical Drug',
			'Branded Drug Comp'
			) -- the only concept class it connects to
	) de
JOIN rl r ON r.concept_class_2 = de.concept_class_id
	AND r.concept_class_1 = 'Clinical Drug Comp'
JOIN ex an ON an.concept_class_id = 'Clinical Drug Comp'
	AND an.rd_combo = de.r_ds -- the q_ds has to match the d_combo of the Clinical Drug Comp
	AND de.concept_code <> an.concept_code
WHERE de.concept_id < 0;

-- Ingredient to Clinical Drug Comp
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_2 = de.concept_class_id
	AND r.concept_class_1 = 'Ingredient'
JOIN (
	-- resolve ri_combo ingredients
	SELECT i.i_code,
		c.concept_code,
		c.vocabulary_id
	FROM ing_stage i
	JOIN concept c ON c.concept_id = i.i_id
	
	UNION
	
	SELECT ri_code,
		ri_code,
		'RxNorm Extension'
	FROM extension_i
	) an ON an.i_code = de.ri_combo
WHERE de.concept_class_id = 'Clinical Drug Comp'
	AND de.concept_id < 0;

-- Ingredients to Clinical Drug Form 
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	(
		SELECT relationship_id
		FROM rl
		WHERE rl.concept_class_1 = 'Ingredient'
			AND rl.concept_class_2 = 'Clinical Drug Form'
		) AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage limit 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN (
	-- resolve ri_combo into i_codes and create rx notation
	SELECT s0.ri_combo,
		s1.concept_code,
		s1.vocabulary_id
	FROM (
		SELECT DISTINCT ri_combo
		FROM extension_attribute
		WHERE concept_id < 0
		) AS s0,
		(
			-- resolve ri_combo ingredients
			SELECT i.i_code, c.concept_code, c.vocabulary_id
			FROM ing_stage i
			JOIN concept c ON c.concept_id = i.i_id

			UNION

			SELECT ri_code, ri_code, 'RxNorm Extension'
			FROM extension_i
			) AS s1
	JOIN LATERAL(SELECT TRIM(UNNEST(REGEXP_MATCHES(s0.ri_combo, '[^-]+', 'g'))) AS parsed_ri_combo) AS l ON l.parsed_ri_combo = s1.i_code
	) an ON an.ri_combo = de.ri_combo
WHERE de.concept_id < 0
	AND de.concept_class_id = 'Clinical Drug Form';

-- Write attribute relationships
-- Dose Forms
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT df.concept_code AS concept_code_1,
	df.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_1 = 'Dose Form'
	AND r.concept_class_2 = de.concept_class_id
JOIN (
	-- resolve df_id - either into existing concept or extension_df
	SELECT concept_code, vocabulary_id, concept_id AS df_id
	FROM concept
	WHERE vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND concept_class_id = 'Dose Form'

	UNION ALL

	SELECT concept_code, vocabulary_id, concept_id
	FROM concept_stage
	WHERE concept_class_id = 'Dose Form' -- the new negative ones
	) df ON df.df_id = de.df_id
WHERE de.concept_id < 0
	AND de.df_id <> 0;

-- Brand Names
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT bn.concept_code AS concept_code_1,
	bn.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_1 = 'Brand Name'
	AND r.concept_class_2 = de.concept_class_id
JOIN (
	-- resolve bn_id - either into existing concept or extension_bn
	SELECT concept_code, vocabulary_id, concept_id AS bn_id
	FROM concept
	WHERE vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND concept_class_id = 'Brand Name'

	UNION ALL

	SELECT concept_code, vocabulary_id, concept_id
	FROM concept_stage
	WHERE concept_class_id = 'Brand Name' -- the new negative ones
	) bn ON bn.bn_id = de.bn_id
WHERE de.concept_id < 0
	AND de.bn_id <> 0;

-- Suppliers
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT mf.concept_code AS concept_code_1,
	mf.vocabulary_id AS vocabulary_id_1,
	de.concept_code AS concept_code_2,
	de.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ex de
JOIN rl r ON r.concept_class_1 = 'Supplier'
	AND r.concept_class_2 = de.concept_class_id
JOIN (
	-- resolve mf_id - either into existing concept or extension_mf
	SELECT concept_code, vocabulary_id, concept_id AS mf_id
	FROM concept
	WHERE vocabulary_id IN (
			'RxNorm',
			'RxNorm Extension'
			)
		AND concept_class_id = 'Supplier'

	UNION ALL

	SELECT concept_code, vocabulary_id, concept_id
	FROM concept_stage
	WHERE concept_class_id = 'Supplier' -- the new negative ones
	) mf ON mf.mf_id = de.mf_id
WHERE de.concept_id < 0
	AND de.mf_id <> 0;

-- Write relationships between Brand Name and Ingredient
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
WITH ri_bn AS (
		SELECT DISTINCT ri_combo,
			bn_id
		FROM extension_attribute
		WHERE concept_id < 0
			AND bn_id < 0
		)
SELECT DISTINCT ing.concept_code AS concept_code_1,
	ing.vocabulary_id AS vocabulary_id_1,
	cs.concept_code AS concept_code_2,
	cs.vocabulary_id AS vocabulary_id_2,
	(
		SELECT relationship_id
		FROM rl
		WHERE concept_class_1 = 'Ingredient'
			AND concept_class_2 = 'Brand Name'
		) AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM ri_bn r
JOIN (
	-- resolve ri_combo into i_codes and create rx notation
	SELECT r.ri_combo,
		s0.concept_code,
		s0.vocabulary_id
	FROM ri_bn r,
		(
			-- resolve ri_combo ingredients
			SELECT i.i_code, c.concept_code, c.vocabulary_id
			FROM ing_stage i
			JOIN concept c ON c.concept_id = i.i_id

			UNION

			SELECT ri_code, ri_code, 'RxNorm Extension'
			FROM extension_i
			) AS s0
	JOIN LATERAL(SELECT TRIM(UNNEST(REGEXP_MATCHES(r.ri_combo, '[^-]+', 'g'))) AS parsed_ri_combo) AS l ON l.parsed_ri_combo = s0.i_code
	) ing ON ing.ri_combo = r.ri_combo
JOIN concept_stage cs ON cs.concept_id = r.bn_id;-- resolve id to code/vocab

-- Write Packs
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT pa.concept_id AS concept_id,
	pn.concept_name AS concept_name,
	'Drug' AS domain_id,
	'RxNorm Extension' AS vocabulary_id,
	pa.concept_class_id,
	'S' AS standard_concept, -- all non-existing packs are Standard
	'OMOP' || NEXTVAL('omop_seq') AS concept_code,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute pa
JOIN pack_name pn ON pn.concept_id = pa.concept_id;

-- Write links between Packs and their containing Drugs
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT -- because drugs can be in a pack in several components
	p.concept_code AS concept_code_1,
	'RxNorm Extension' AS vocabulary_id_1,
	COALESCE(cs.concept_code, c.concept_code) AS concept_code_2,
	COALESCE(cs.vocabulary_id, c.vocabulary_id) AS vocabulary_id_2,
	'Contains' AS relationship_id, -- the relationship_id is not taken from rl, but expicitly defined
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute pa
JOIN concept_stage p ON p.concept_id = pa.concept_id -- get concept_code/vocab pair of pack, equivalent of ex
JOIN (
	-- split components by ';' and extract the drug (behind '/')
	SELECT s0.concept_id,
		SUBSTR(s0.component, devv5.instr(s0.component, '/', 1) + 1)::int4 AS drug_concept_id
	FROM (
		SELECT p.concept_id,
			TRIM(UNNEST(REGEXP_MATCHES(p.components, '[^;]+', 'g'))) AS component
		FROM pack_attribute p
		) AS s0
	) s1 ON s1.concept_id = pa.concept_id
LEFT JOIN concept_stage cs ON cs.concept_id = s1.drug_concept_id -- get concept_code/vocab for new drug
LEFT JOIN concept c ON c.concept_id = s1.drug_concept_id;-- or existing drug

-- Write inner relationships for Packs: has tradename, available as box, has marketed form
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
WITH mixed AS (
		-- create mixed q and r ancestors, descendants can only be new
		SELECT DISTINCT COALESCE(anc.concept_id, ancs.concept_id) AS concept_id,
			COALESCE(anc.concept_code, ancs.concept_code) AS concept_code,
			COALESCE(anc.vocabulary_id, ancs.vocabulary_id) AS vocabulary_id,
			fp.concept_class_id,
			fp.components,
			fp.bn_id,
			fp.bs,
			fp.mf_id
		FROM full_pack fp
		LEFT JOIN pack_attribute pa ON pa.components = fp.components
			AND pa.bn_id = fp.bn_id
			AND pa.bs = fp.bs
			AND pa.mf_id = fp.mf_id
		LEFT JOIN concept_stage ancs ON ancs.concept_id = pa.concept_id
		LEFT JOIN concept anc ON anc.concept_id = fp.r_concept_id
		)
SELECT DISTINCT an.concept_code AS concept_code_1,
	an.vocabulary_id AS vocabulary_id_1,
	decs.concept_code AS concept_code_2,
	decs.vocabulary_id AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute de
JOIN concept_stage decs ON decs.concept_id = de.concept_id -- get concept_code/vocab pair of pack
JOIN rl r ON r.concept_class_2 = de.concept_class_id
JOIN mixed an ON r.concept_class_1 = an.concept_class_id -- ancestors can be both from pack_attribute as well as r_existing_pack
	AND de.components = an.components -- the d_combos have to match completely
	AND de.bn_id = CASE an.bn_id
		WHEN 0
			THEN de.bn_id
		ELSE an.bn_id
		END -- the descendant may not have a bn
	AND de.bs = CASE an.bs
		WHEN 0
			THEN de.bs
		ELSE an.bs
		END -- the descendant may not have bs
	AND de.bn_id = CASE an.bn_id
		WHEN 0
			THEN de.bn_id
		ELSE an.bn_id
		END -- the descendant may not have a bn
	AND de.concept_id <> an.concept_id;-- to avoid linking to self

-- Write Brand Names for Packs
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT COALESCE(bs.concept_code, b.concept_code) AS concept_code_1,
	COALESCE(bs.vocabulary_id, b.vocabulary_id) AS vocabulary_id_1,
	p.concept_code AS concept_code_2,
	'RxNorm Extension' AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute pa
JOIN concept_stage p ON p.concept_id = pa.concept_id -- get concept_code/vocab pair of pack
JOIN rl r ON r.concept_class_1 = 'Brand Name'
	AND r.concept_class_2 = p.concept_class_id
LEFT JOIN concept_stage bs ON bs.concept_id = pa.bn_id
LEFT JOIN concept b ON b.concept_id = pa.bn_id
WHERE pa.bn_id <> 0;-- has no translation and brand name

-- Write Suppliers for Packs
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT COALESCE(ms.concept_code, m.concept_code) AS concept_code_1,
	COALESCE(ms.vocabulary_id, m.vocabulary_id) AS vocabulary_id_1,
	p.concept_code AS concept_code_2,
	'RxNorm Extension' AS vocabulary_id_2,
	r.relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute pa
JOIN concept_stage p ON p.concept_id = pa.concept_id -- get concept_code/vocab pair of pack
JOIN rl r ON r.concept_class_1 = 'Supplier'
	AND r.concept_class_2 = p.concept_class_id
LEFT JOIN concept_stage ms ON ms.concept_id = pa.mf_id
LEFT JOIN concept m ON m.concept_id = pa.mf_id
WHERE pa.mf_id <> 0;-- has no translation and supplier

-- Create content for packs
INSERT INTO pack_content_stage
SELECT DISTINCT p.concept_code AS pack_concept_code,
	p.vocabulary_id AS pack_vocabulary_id,
	COALESCE(ds.concept_code, dc.concept_code) AS drug_concept_code,
	COALESCE(ds.vocabulary_id, dc.vocabulary_id) drug_vocabulary_id,
	NULLIF(c.amount, 0) AS amount,
	NULLIF(pa.bs, 0) AS box_size
FROM pack_attribute pa
JOIN concept_stage p ON p.concept_id = pa.concept_id -- get concept_code/vocab pair of pack, equivalent of ex
JOIN (
	-- split components by ';' and extract the drug (behind '/')
	SELECT concept_id,
		SUBSTR(s0.component, 1, devv5.instr(s0.component, '/', 1) - 1)::NUMERIC AS amount,
		SUBSTR(s0.component, devv5.instr(s0.component, '/', 1) + 1)::INT4 AS drug_concept_id
	FROM (
		-- break up the components string
		SELECT concept_id,
			TRIM(UNNEST(REGEXP_MATCHES(components, '[^;]+', 'g'))) AS component
		FROM pack_attribute -- extension_combo contains i_combos as well
		) AS s0
	) c ON c.concept_id = pa.concept_id
LEFT JOIN concept_stage ds ON ds.concept_id = c.drug_concept_id
LEFT JOIN concept dc ON dc.concept_id = c.drug_concept_id;

/************************
* 14. Write source vocab *
************************/

-- Write source drugs as non-standard
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT 0 AS concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	COALESCE(source_concept_class_id, concept_class_id) AS concept_class_id,
	NULL AS standard_concept, -- Source Concept, no matter whether active or not
	concept_code,
	COALESCE(valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = (
					SELECT vocabulary_id
					FROM drug_concept_stage LIMIT 1
					)
			)) AS valid_start_date,
	COALESCE(valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	CASE invalid_reason
		WHEN 'U'
			THEN 'D'
		ELSE invalid_reason
		END AS invalid_reason
FROM drug_concept_stage
WHERE concept_class_id IN (
		'Ingredient',
		'Drug Product',
		'Supplier',
		'Dose Form',
		'Brand Name'
		) -- but no Unit
	AND COALESCE(domain_id, 'Drug') = 'Drug';

-- Write source devices as standard (unless deprecated)
INSERT INTO concept_stage (
	concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT 0 AS concept_id,
	concept_name,
	domain_id,
	vocabulary_id,
	COALESCE(source_concept_class_id, concept_class_id) AS concept_class_id,
	CASE 
		WHEN invalid_reason IS NULL
			THEN 'S'
		ELSE NULL
		END AS standard_concept, -- Devices are not mapped
	concept_code,
	COALESCE(valid_start_date, (
			SELECT latest_update
			FROM vocabulary v
			WHERE v.vocabulary_id = (
					SELECT vocabulary_id
					FROM drug_concept_stage LIMIT 1
					)
			)) AS valid_start_date,
	COALESCE(valid_end_date, TO_DATE('20991231', 'yyyymmdd')) AS valid_end_date,
	invalid_reason -- if they are 'U' they get mapped using Maps to to RxNorm/E anyway
FROM drug_concept_stage
WHERE domain_id = 'Device';

ANALYZE concept_stage;

-- Write maps for drugs
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT m.from_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	e.concept_code AS concept_code_2,
	e.vocabulary_id AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM maps_to m
JOIN ex e ON e.concept_id = m.to_id;

-- Write maps for Ingredients
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT i_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	concept_code AS concept_code_2,
	vocabulary_id AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT x.qi_combo AS i_code,
		c.concept_code,
		c.vocabulary_id
	FROM x_ing x
	JOIN ing_stage i ON i.i_code = x.ri_combo
	JOIN concept c ON c.concept_id = i.i_id -- translate to existing RxE ones
	
	UNION
	
	SELECT qi_code,
		ri_code,
		'RxNorm Extension'
	FROM extension_i -- translate to new RxNorm Extension ones, lookup in concept_stage no necessary as it still has the XXX code
	) AS s0;

-- Write maps for Dose Forms
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT df_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	concept_code AS concept_code_2,
	vocabulary_id AS vocabulary_id_2,
	'Source - RxNorm eq' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT x.df_code,
		c.concept_code,
		c.vocabulary_id
	FROM x_df x
	JOIN concept c ON c.concept_id = x.df_id -- translate to existing RxE ones
	
	UNION
	
	SELECT df.df_code,
		cs.concept_code,
		cs.vocabulary_id
	FROM extension_df df
	JOIN concept_stage cs ON cs.concept_id = df.df_id -- translate to new RxNorm Extension ones
	) AS s0;

-- Write maps for Brand Names
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT bn_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	concept_code AS concept_code_2,
	vocabulary_id AS vocabulary_id_2,
	'Source - RxNorm eq' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT x.bn_code,
		c.concept_code,
		c.vocabulary_id
	FROM x_bn x
	JOIN concept c ON c.concept_id = x.bn_id
	
	UNION
	
	SELECT bn.bn_code,
		cs.concept_code,
		cs.vocabulary_id
	FROM extension_bn bn
	JOIN concept_stage cs ON cs.concept_id = bn.bn_id
	) AS s0;

-- Write maps for Suppliers
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT mf_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	concept_code AS concept_code_2,
	vocabulary_id AS vocabulary_id_2,
	'Source - RxNorm eq' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM (
	SELECT x.mf_code,
		c.concept_code,
		c.vocabulary_id
	FROM x_mf x
	JOIN concept c ON c.concept_id = x.mf_id
	
	UNION
	
	SELECT mf.mf_code,
		cs.concept_code,
		cs.vocabulary_id
	FROM extension_mf mf
	JOIN concept_stage cs ON cs.concept_id = mf.mf_id
	) AS s0;

-- Write relationship to drug classes like ATC
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT e.concept_code AS concept_code_1,
	e.vocabulary_id AS vocabulary_id_1,
	dc.concept_code AS concept_code_2,
	dc.vocabulary_id AS vocabulary_id_2,
	'Drug has drug class' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM maps_to m
JOIN ex e ON e.concept_id = m.to_id
JOIN r_to_c rtc ON rtc.concept_code_1 = m.from_code
JOIN concept dc ON dc.concept_id = rtc.concept_id_2
WHERE dc.vocabulary_id IN (
		SELECT c_int.vocabulary_id
		FROM concept c_int
		WHERE c_int.domain_id = 'Drug'
			AND c_int.standard_concept = 'C'
		);

-- Write maps for Packs
INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT -- because each pack has many drugs
	fp.q_concept_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	c.concept_code AS concept_code_2,
	c.vocabulary_id AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM full_pack fp
JOIN concept c ON c.concept_id = fp.r_concept_id
WHERE fp.r_concept_id IS NOT NULL
	AND fp.q_concept_code IS NOT NULL;

INSERT INTO concept_relationship_stage (
	concept_code_1,
	vocabulary_id_1,
	concept_code_2,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date,
	invalid_reason
	)
SELECT DISTINCT -- because each pack has many drugs
	fp.q_concept_code AS concept_code_1,
	(
		SELECT vocabulary_id
		FROM drug_concept_stage LIMIT 1
		) AS vocabulary_id_1,
	cs.concept_code AS concept_code_2,
	cs.vocabulary_id AS vocabulary_id_2,
	'Maps to' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM pack_attribute pa
JOIN concept_stage cs ON cs.concept_id = pa.concept_id
JOIN full_pack fp ON fp.components = pa.components
	AND fp.bn_id = pa.bn_id
	AND fp.bs = pa.bs
	AND fp.mf_id = pa.mf_id
WHERE fp.q_concept_code IS NOT NULL;

-- Build drug_strength_stage
INSERT INTO drug_strength_stage
SELECT cs.concept_code AS drug_concept_code,
	cs.vocabulary_id AS drug_vocabulary_id,
	COALESCE(i.ingredient_concept_code, s1.i_code) AS ingredient_concept_code,
	COALESCE(i.ingredient_vocabulary_id, 'RxNorm Extension') AS ingredient_concept_code,
	NULLIF(s1.amount_value, 0) AS amount_value,
	NULLIF(s1.amount_unit_concept_id, 0) AS amount_unit_concept_id,
	CASE 
		WHEN s1.numerator_unit_concept_id IN (
				8554,
				9325,
				9324
				)
			THEN numerator_value -- don't multiply with denominator for %, D, X
		WHEN ea.r_value = 0
			THEN NULLIF(s1.numerator_value, 0) -- non-quantified
		ELSE CASE s1.numerator_value * ea.r_value
				WHEN 0
					THEN 0
				ELSE ROUND((s1.numerator_value * ea.r_value)::NUMERIC, (3 - FLOOR(LOG(s1.numerator_value * ea.r_value)) - 1)::INT)
				END
		END AS numerator_value,
	NULLIF(s1.numerator_unit_concept_id, 0) AS numerator_unit_concept_id,
	NULLIF(ea.r_value, 0) AS denominator_value,
	NULLIF(s1.denominator_unit_concept_id, 0) AS denominator_unit_concept_id,
	(
		SELECT latest_update
		FROM vocabulary v
		WHERE v.vocabulary_id = (
				SELECT vocabulary_id
				FROM drug_concept_stage LIMIT 1
				)
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date,
	NULL AS invalid_reason
FROM extension_attribute ea
JOIN (
	SELECT rd_combo,
		rd_combo AS r_ds
	FROM extension_attribute
	WHERE rd_combo NOT LIKE '%-%'
		AND rd_combo <> ' ' -- singletons
	
	UNION
	
	SELECT rd_combo,
		r_ds
	FROM r_breakup -- break up combos
	) AS s0 ON s0.rd_combo = ea.rd_combo -- resolve combos
JOIN (
	-- get the strength detail, either from r or the new extension
	SELECT *
	FROM r_uds
	
	UNION
	
	SELECT *
	FROM extension_uds
	) AS s1 ON s1.ds_code = s0.r_ds
JOIN concept_stage cs ON cs.concept_id = ea.concept_id -- get concept_code/vocab representation, instead of concept_id
LEFT JOIN (
	-- resolve ingredients
	SELECT ing.i_code,
		c.concept_code AS ingredient_concept_code,
		c.vocabulary_id AS ingredient_vocabulary_id
	FROM ing_stage ing
	JOIN concept c ON c.concept_id = ing.i_id
	) i ON i.i_code = s1.i_code
WHERE ea.concept_id < 1;

/**************
* 15. Tidy up *
**************/

-- Replace concept_codes XXX123 with OMOP123
-- Create replacement map
DROP TABLE IF EXISTS xxx_replace;
CREATE TABLE xxx_replace (
	xxx_code VARCHAR(50),
	omop_code VARCHAR(50)
	);

-- generate OMOP codes for new concepts
INSERT INTO xxx_replace
SELECT concept_code AS xxx_code,
	'OMOP' || NEXTVAL('omop_seq') AS omop_code
FROM concept_stage
WHERE concept_code LIKE 'XXX%';

-- replace concept_stage
UPDATE concept_stage cs
SET concept_code = x.omop_code
FROM xxx_replace x
WHERE cs.concept_code = x.xxx_code;

-- replace concept_relationship_stage
UPDATE concept_relationship_stage crs
SET concept_code_1 = x.omop_code
FROM xxx_replace x
WHERE crs.concept_code_1 = x.xxx_code;

UPDATE concept_relationship_stage crs
SET concept_code_2 = x.omop_code
FROM xxx_replace x
WHERE crs.concept_code_2 = x.xxx_code;

-- replace ingredients in drug_strength
UPDATE drug_strength_stage ds
SET ingredient_concept_code = x.omop_code
FROM xxx_replace x
WHERE ds.ingredient_concept_code = x.xxx_code;

-- Remove negative and 0 concept_ids from concept_stage
UPDATE concept_stage
SET concept_id = NULL;

--get duplicates for some reason
DELETE
FROM concept_relationship_stage crs
WHERE EXISTS (
		SELECT 1
		FROM concept_relationship_stage crs_int
		WHERE crs_int.concept_code_1 = crs.concept_code_1
			AND crs_int.concept_code_2 = crs.concept_code_2
			AND crs_int.vocabulary_id_1 = crs.vocabulary_id_1
			AND crs_int.vocabulary_id_2 = crs.vocabulary_id_2
			AND crs_int.relationship_id = crs.relationship_id
			AND crs_int.ctid > crs.ctid
		);

-- Working with replacement mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.CheckReplacementMappings();
END $_$;

-- Add mapping from deprecated to fresh concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMAPSTO();
END $_$;

-- Deprecate 'Maps to' mappings to deprecated and upgraded concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeprecateWrongMAPSTO();
END $_$;

-- Delete ambiguous 'Maps to' mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeleteAmbiguousMAPSTO();
END $_$;

-- Clean up tables
DROP TABLE r_to_c;
DROP SEQUENCE ds_seq;
DROP SEQUENCE xxx_seq;
DROP SEQUENCE extension_id;
DROP TABLE q_ing;
DROP TABLE ds_rounded;
DROP TABLE q_uds;
DROP TABLE q_ds;
DROP TABLE q_combo;
DROP TABLE q_quant;
DROP TABLE q_df;
DROP TABLE q_bn;
DROP TABLE q_mf;
DROP TABLE q_bs;
DROP TABLE q_existing;
DROP TABLE ing_stage;
DROP TABLE r_ing;
DROP TABLE r_uds;
DROP TABLE r_ds;
DROP TABLE r_combo;
DROP TABLE r_quant;
DROP TABLE r_df;
DROP TABLE r_bn;
DROP TABLE r_mf;
DROP TABLE r_bs;
DROP TABLE r_existing;
DROP TABLE qr_uds;
DROP TABLE qr_ds;
DROP TABLE qr_d_combo;
DROP TABLE qr_i;
DROP TABLE qr_i_combo;
DROP TABLE qr_quant;
DROP TABLE qr_ing;
DROP TABLE qr_df;
DROP TABLE qr_bn;
DROP TABLE qr_mf;
DROP TABLE x_unit;
DROP TABLE dfg;
DROP TABLE x_pattern;
DROP TABLE x_ing;
DROP TABLE x_df;
DROP TABLE x_bn;
DROP TABLE x_mf;
DROP TABLE extension_i;
DROP TABLE extension_uds;
DROP TABLE reduce_euds;
DROP TABLE extension_ds;
DROP TABLE extension_combo;
DROP TABLE extension_df;
DROP TABLE extension_bn;
DROP TABLE extension_mf;
DROP TABLE full_corpus;
DROP TABLE q_breakup;
DROP TABLE r_breakup;
DROP TABLE extension_attribute;
DROP TABLE maps_to;
DROP TABLE rxnorm_unit;
DROP TABLE spelled_out;
DROP TABLE extension_name;
DROP TABLE q_existing_pack;
DROP TABLE r_existing_pack;
DROP TABLE full_pack;
DROP TABLE pack_attribute;
DROP TABLE pack_name;
DROP SEQUENCE omop_seq;
DROP TABLE rl;
DROP TABLE ex;
DROP TABLE xxx_replace;

/*-- create a mapping lookup to check boiler's results
DROP TABLE nccd_mapping_lookup_3;
CREATE TABLE nccd_mapping_lookup_3 
AS
(SELECT DISTINCT a.vocabulary_id AS source_vocabulary_id,
       a.domain_id AS source_domain_id,
       a.concept_class_id AS source_concept_class_id,
       a.standard_concept,
       a.concept_code AS source_code,
       a.concept_name AS source_name,
       b.relationship_id,
       COALESCE(c.concept_id,0) AS concept_id,
       COALESCE(c.concept_code,d.concept_code,'') AS concept_code,
       COALESCE(c.concept_name,d.concept_name,'') AS concept_name,
       COALESCE(c.domain_id,d.domain_id,'') AS domain_id,
       COALESCE(c.vocabulary_id,d.vocabulary_id,'') AS vocabulary_id,
       a.concept_id AS junk_flag
FROM concept_stage a
  LEFT JOIN concept_relationship_stage b ON (a.concept_code,a.vocabulary_id) = (b.concept_code_1,b.vocabulary_id_1)
  LEFT JOIN concept c
         ON (b.concept_code_2,b.vocabulary_id_2) = (c.concept_code,c.vocabulary_id)
        AND c.standard_concept = 'S'
  LEFT JOIN concept_stage d ON (b.concept_code_2,b.vocabulary_id_2) = (d.concept_code,d.vocabulary_id) 
  WHERE a.vocabulary_id = 'NCCD');

-- look at one to many mappings 
select * from dev_nccd.nccd_mapping_lookup_3 where source_code in (select source_code from nccd_mapping_lookup_2 group by  source_code having count (1)>1); 
*/
