/**************************************************************************
* Copyright 2016 Observational Health Data Sciences and Informatics (OHDSI)
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
* 
* Authors: Timur Vakhitov, Christian Reich
* Date: 2016
**************************************************************************/

-- 1. Update latest_update field to new date 
BEGIN
   DEVV5.VOCABULARY_PACK.SetLatestUpdate (pVocabularyName        => 'ICD10CM',
                                          pVocabularyDate        => TO_DATE ('20161001', 'yyyymmdd'), --The 2017 changes became effective on October 1, 2016.
                                          pVocabularyVersion     => 'ICD10CM FY2017 code descriptions',
                                          pVocabularyDevSchema   => 'DEV_ICD10CM');
END;
/
COMMIT;

-- 2. Truncate all working tables
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE concept_synonym_stage;
TRUNCATE TABLE pack_content_stage;
TRUNCATE TABLE drug_strength_stage;

--3. Load into concept_stage from ICD10CM_TABLE
INSERT /*+ APPEND */ INTO concept_stage (concept_id,
                           concept_name,
                           domain_id,
                           vocabulary_id,
                           concept_class_id,
                           standard_concept,
                           concept_code,
                           valid_start_date,
                           valid_end_date,
                           invalid_reason)
   SELECT NULL AS concept_id,
          SUBSTR (
             CASE
                WHEN LENGTH (LONG_NAME) > 255 AND SHORT_NAME IS NOT NULL
                THEN
                   SHORT_NAME
                ELSE
                   LONG_NAME
             END,
             1,
             255)
             AS concept_name,
          NULL AS domain_id,
          'ICD10CM' AS vocabulary_id,
          CASE
             WHEN CODE_TYPE = 1 THEN LENGTH (code) || '-char billing code'
             ELSE LENGTH (code) || '-char nonbill code'
          END
             AS concept_class_id,
          NULL AS standard_concept,
          REGEXP_REPLACE (code, '([[:print:]]{3})([[:print:]]+)', '\1.\2') -- Dot after 3 characters
             AS concept_code,
          (SELECT latest_update
             FROM vocabulary
            WHERE vocabulary_id = 'ICD10CM')
             AS valid_start_date,
          TO_DATE ('20991231', 'yyyymmdd') AS valid_end_date,
          NULL AS invalid_reason
     FROM ICD10CM_TABLE;
     /
COMMIT;					  

/* temporary disabled for later use
select * from concept_stage
;
drop TABLE CONCEPT_RELATION_pre_MANUAL;
CREATE TABLE CONCEPT_RELATION_pre_MANUAL
(
   CONCEPT_CODE_1     VARCHAR2 (50 BYTE) ,
   concept_name_1 varchar (250),
   VOCABULARY_ID_1    VARCHAR (20), 
   invalid_reason_1  VARCHAR2 (1 BYTE),
   CONCEPT_CODE_2     VARCHAR2 (50 BYTE) ,
   concept_name_2 varchar (250),
   concept_class_id_2 varchar (250),
   VOCABULARY_ID_2    VARCHAR (20) ,
   invalid_reason_2  VARCHAR2 (1 BYTE),
   RELATIONSHIP_ID    VARCHAR2 (20 BYTE) ,
   VALID_START_DATE   DATE,
   VALID_END_DATE     DATE,
   INVALID_REASON     VARCHAR2 (1 BYTE)
)
NOLOGGING
;


--5. Create file with mappings for medical coder from the existing one
-- instead of concept use concept_stage (medical coders need to review new concepts also)
-- need to add more useful attributes exactly to concept_relationship_manual to make the manual mapping process easier
-- create temporary table CONCEPT_RELATION_pre_MANUAL that will be filled by the medical coder
truncate table CONCEPT_RELATION_pre_MANUAL;
insert into CONCEPT_RELATION_pre_MANUAL (CONCEPT_CODE_1,CONCEPT_NAME_1,VOCABULARY_ID_1,invalid_reason_1, CONCEPT_CODE_2,CONCEPT_NAME_2,CONCEPT_CLASS_ID_2,VOCABULARY_ID_2,invalid_reason_2, RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON)
SELECT c.concept_code,c.concept_name,c.vocabulary_id,c.invalid_reason, t.concept_code, t.concept_name,t.concept_class_id,t.vocabulary_id,t.invalid_reason, r.RELATIONSHIP_ID, r.VALID_START_DATE, r.VALID_END_DATE, r.INVALID_REASON
  FROM concept_stage c
 left join  concept_relationship r on c.concept_id = r.concept_id_1 and r.relationship_id in ('Maps to', 'Maps to value') -- for this case other relationships shouldn't be checked manualy
 left join concept t on t.concept_id = r.concept_id_2
;
select * from CONCEPT_RELATION_pre_MANUAL
;
!!!Stop script - give the result to medical coder who will fill concept_relationship_manual based on CONCEPT_RELATION_pre_MANUAL--, remember concept_relatopnshoip_stage is empty for now
--need to think if we need to give only those where concept_code_2 is null or it's mappped only to deprecated concept
-- if medical coder wants to change relatoinship (i.e. found a better mapping - set an old row as deprecated, add a new row to concept_relationship)
;
--do it once CONCEPT_RELATION_pre_MANUAL is done by medical coder
--or probably another temporary table can be used where we put the result of manual mappings
insert into concept_relationship_manual (CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON)
select CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON from CONCEPT_RELATION_pre_MANUAL
;
commit
;
*/
--May 2017 hotfix
truncate table concept_relationship_manual 
;
commit
;
--existing mappings
insert into concept_relationship_manual (CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON)
select c.concept_code, d.concept_code, c.vocabulary_id, d.vocabulary_id,r.relationship_id, r.VALID_START_DATE, r.VALID_END_DATE, r.INVALID_REASON from concept c
join concept_relationship r on c.concept_id = r.concept_id_1 and r.relationship_id in ('Maps to', 'Maps to value') and r.invalid_reason is null
join concept d on d.concept_id = r.concept_id_2 and d.invalid_reason is null
and c.vocabulary_id = 'ICD10CM'
where c.concept_code not in (select concept_code_1 from MAP_052017) and c.invalid_reason is null
;
--add the concepts from Erica and Ajit
insert into concept_relationship_manual (CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON)
select CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID, TRUNC(SYSDATE) -1, to_date  ('31122099', 'ddmmyyyy') , null from MAP_052017
;
--add the concepts from the manual work done before that somehow didn't present in concept_relationship now
insert into concept_relationship_manual (CONCEPT_CODE_1,CONCEPT_CODE_2,VOCABULARY_ID_1,VOCABULARY_ID_2,RELATIONSHIP_ID,VALID_START_DATE,VALID_END_DATE,INVALID_REASON)
select source_code, target_code,'ICD10CM', 'SNOMED', MAPPING_TYPE, TRUNC(SYSDATE) -1, to_date  ('31122099', 'ddmmyyyy') , null  from ims_map.ICD10CM_MAP120316 
join concept i on i.concept_code = SOURCE_CODE and i.vocabulary_id ='ICD10CM'
join concept s on s.concept_code = TARGET_CODE and s.vocabulary_id = 'SNOMED' and (s.invalid_reason is null or s.invalid_reason='U')
where SOURCE_CODE not in (select concept_code_1 from concept_relationship_manual)
;
commit
;
--4 Add ICD10CM to SNOMED manual mappings
BEGIN
   DEVV5.VOCABULARY_PACK.ProcessManualRelationships;
END;
/
COMMIT;

--5 Working with replacement mappings
BEGIN
   DEVV5.VOCABULARY_PACK.CheckReplacementMappings;
END;
/
COMMIT;

--6 Deprecate 'Maps to' mappings to deprecated and upgraded concepts
BEGIN
   DEVV5.VOCABULARY_PACK.DeprecateWrongMAPSTO;
END;
/
COMMIT;		

--7 Add mapping from deprecated to fresh concepts
BEGIN
   DEVV5.VOCABULARY_PACK.AddFreshMAPSTO;
END;
/
COMMIT;

--8 Delete ambiguous 'Maps to' mappings
BEGIN
   DEVV5.VOCABULARY_PACK.DeleteAmbiguousMAPSTO;
END;
/
COMMIT;

--9 Add "subsumes" relationship between concepts where the concept_code is like of another
INSERT INTO concept_relationship_stage (concept_code_1,
                                        concept_code_2,
                                        vocabulary_id_1,
                                        vocabulary_id_2,
                                        relationship_id,
                                        valid_start_date,
                                        valid_end_date,
                                        invalid_reason)
   SELECT c1.concept_code AS concept_code_1,
          c2.concept_code AS concept_code_2,
          c1.vocabulary_id AS vocabulary_id_1,
          c1.vocabulary_id AS vocabulary_id_2,
          'Subsumes' AS relationship_id,
          (SELECT latest_update
             FROM vocabulary
            WHERE vocabulary_id = c1.vocabulary_id)
             AS valid_start_date,
          TO_DATE ('20991231', 'yyyymmdd') AS valid_end_date,
          NULL AS invalid_reason
     FROM concept_stage c1, concept_stage c2
    WHERE     c2.concept_code LIKE c1.concept_code || '%'
          AND c1.concept_code <> c2.concept_code
          AND NOT EXISTS
                 (SELECT 1
                    FROM concept_relationship_stage r_int
                   WHERE     r_int.concept_code_1 = c1.concept_code
                         AND r_int.concept_code_2 = c2.concept_code
                         AND r_int.relationship_id = 'Subsumes');
COMMIT;



--10 Update domain_id for ICD10CM from SNOMED
--create 1st temporary table ICD10CM_domain with direct mappings
create table filled_domain NOLOGGING as
	with domain_map2value as (--ICD10CM have direct "Maps to value" mapping
		SELECT c1.concept_code, c2.domain_id
		FROM concept_relationship_stage r, concept_stage c1, concept c2
		WHERE c1.concept_code=r.concept_code_1 AND c2.concept_code=r.concept_code_2
		AND c1.vocabulary_id=r.vocabulary_id_1 AND c2.vocabulary_id=r.vocabulary_id_2
		AND r.vocabulary_id_1='ICD10CM' AND r.vocabulary_id_2='SNOMED'
		AND r.relationship_id='Maps to value'
		AND r.invalid_reason is null
	)
	select 
	d.concept_code,
	--some rules for domain_id
	case    when d.domain_id in ('Procedure', 'Measurement') 
				and exists (select 1 from domain_map2value t where t.concept_code=d.concept_code and t.domain_id in ('Meas Value' , 'Spec Disease Status'))
				then 'Measurement'
			when d.domain_id = 'Procedure' and exists (select 1 from domain_map2value t where t.concept_code=d.concept_code and t.domain_id = 'Condition')
				then 'Condition'
			when d.domain_id = 'Condition' and exists (select 1 from domain_map2value t where t.concept_code=d.concept_code and t.domain_id = 'Procedure')
				then 'Condition' 
			when d.domain_id = 'Observation' 
				then 'Observation'                 
			else d.domain_id
	end domain_id
	FROM --simplify domain_id
	( select concept_code,
		case when domain_id='Condition/Measurement' then 'Condition'
			 when domain_id='Condition/Procedure' then 'Condition'
			 when domain_id='Condition/Observation' then 'Observation'
			 when domain_id='Observation/Procedure' then 'Observation'
			 when domain_id='Measurement/Observation' then 'Observation'
			 when domain_id='Measurement/Procedure' then 'Measurement'
			 else 'Condition' --if some concepts don't have any mappings, 'Condition' by default for ICD10CM
		end domain_id
		from ( --ICD10CM have direct "Maps to" mapping
			select concept_code, listagg(domain_id,'/') within group (order by domain_id) domain_id from (
				SELECT distinct c1.concept_code, c2.domain_id
				FROM concept_relationship_stage r, concept_stage c1, concept c2
				WHERE c1.concept_code=r.concept_code_1 AND c2.concept_code=r.concept_code_2
				AND c1.vocabulary_id=r.vocabulary_id_1 AND c2.vocabulary_id=r.vocabulary_id_2
				AND r.vocabulary_id_1='ICD10CM' AND r.vocabulary_id_2='SNOMED'
				AND r.relationship_id='Maps to'
				AND r.invalid_reason is null
			)
			group by concept_code
		)
	) d;

--create 2d temporary table with ALL ICD10CM domains
--if domain_id is empty we use previous and next domain_id or its combination
create table ICD10CM_domain NOLOGGING as
    select concept_code, 
    case when domain_id is not null then domain_id 
    else 
        case when prev_domain=next_domain then prev_domain --prev and next domain are the same (and of course not null both)
            when prev_domain is not null and next_domain is not null then  
                case when prev_domain<next_domain then prev_domain||'/'||next_domain 
                else next_domain||'/'||prev_domain 
                end -- prev and next domain are not same and not null both, with order by name
            else coalesce (prev_domain,next_domain,'Unknown')
        end
    end domain_id
    from (
            select concept_code, LISTAGG(domain_id, '/') WITHIN GROUP (order by domain_id) domain_id, prev_domain, next_domain from (

                        select distinct c1.concept_code, r1.domain_id,
                            (select MAX(fd.domain_id) KEEP (DENSE_RANK LAST ORDER BY fd.concept_code) from filled_domain fd where fd.concept_code<c1.concept_code and r1.domain_id is null) prev_domain,
                            (select MIN(fd.domain_id) KEEP (DENSE_RANK FIRST ORDER BY fd.concept_code) from filled_domain fd where fd.concept_code>c1.concept_code and r1.domain_id is null) next_domain
                        from concept_stage c1
                        left join filled_domain r1 on r1.concept_code=c1.concept_code
                        where c1.vocabulary_id='ICD10CM'
            )
            group by concept_code,prev_domain, next_domain
    );

-- INDEX was set as UNIQUE to prevent concept_code duplication
CREATE UNIQUE INDEX idx_ICD10CM_domain ON ICD10CM_domain (concept_code) NOLOGGING;

--11 Simplify the list by removing Observations
update ICD10CM_domain set domain_id=trim('/' FROM replace('/'||domain_id||'/','/Observation/','/'))
where '/'||domain_id||'/' like '%/Observation/%'
and instr(domain_id,'/')<>0;

--Reducing some domain_id if his length>20
update ICD10CM_domain set domain_id='Condition/Meas' where domain_id='Condition/Measurement';

COMMIT;

-- Check that all domain_id are exists in domain table
ALTER TABLE ICD10CM_domain ADD CONSTRAINT fk_ICD10CM_domain FOREIGN KEY (domain_id) REFERENCES domain (domain_id)--; select * from domain; select * from ICD10CM_domain;-- of course it doesn't work at all because we don't have any mappings
;

--12 Update each domain_id with the domains field from ICD10CM_domain.
UPDATE concept_stage c
   SET (domain_id) =
          (SELECT domain_id
             FROM ICD10CM_domain rd
            WHERE rd.concept_code = c.concept_code)
 WHERE c.vocabulary_id = 'ICD10CM';
COMMIT;

--13 Load into concept_synonym_stage name from ICD10CM_TABLE
INSERT /*+ APPEND */ INTO concept_synonym_stage (synonym_concept_id,
                                   synonym_concept_code,
                                   synonym_name,
                                   synonym_vocabulary_id,
                                   language_concept_id)
   SELECT DISTINCT NULL AS synonym_concept_id,
                   code AS synonym_concept_code,
                   DESCRIPTION AS synonym_name,
                   'ICD10CM' AS synonym_vocabulary_id,
                   4180186 AS language_concept_id                   -- English
     FROM (SELECT LONG_NAME,
                  SHORT_NAME,
                  REGEXP_REPLACE (code,
                                  '([[:print:]]{3})([[:print:]]+)',
                                  '\1.\2')
                     AS code
             FROM ICD10CM_TABLE) UNPIVOT (DESCRIPTION --take both LONG_NAME and SHORT_NAME
                                 FOR DESCRIPTIONS
                                 IN (LONG_NAME, SHORT_NAME));
COMMIT;

--14 Clean up
DROP TABLE ICD10CM_domain PURGE;
DROP TABLE filled_domain PURGE;	
--drop TABLE CONCEPT_RELATION_pre_MANUAL;
-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script		