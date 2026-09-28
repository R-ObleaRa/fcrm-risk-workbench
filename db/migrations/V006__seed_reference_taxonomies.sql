-- =============================================================================
-- V006  Frameworks and initial reference taxonomies (version 1, active)
--
-- The risk decomposition is grounded in published frameworks, not invented:
--   * FATF Recommendations (international standard): R.1, R.3, R.5, R.6, R.7,
--     R.15, INR.1 and the Glossary's designated categories of offences
--   * EBA ML/TF Risk Factors Guidelines, EBA/GL/2021/02 (supervisory
--     guideline): paragraph 1.22 and Guideline 2 risk-factor sections
--   * Wolfsberg Risk Assessment FAQs 2015 (industry guidance): the
--     inherent / control / residual method, control categories, rating scales
--
-- Taxonomies that define risk, controls or ratings require every term to cite
-- at least one provision (ref.taxonomy.requires_framework_basis). Internal
-- classifications (geography codes, segments, channels, product families,
-- document types) do not.
--
-- Provisions within EBA Guideline 2 are cited by section heading; the
-- paragraph numbers inside Guideline 2 were not verifiable from the published
-- text and are deliberately not asserted.
--
-- Later changes must go through the governed path: new draft taxonomy_version,
-- grounded terms (with supersedes_term_id), then supersede and activate in one
-- transaction.
-- =============================================================================

select set_config('fcrm.actor_id', 'system:migration', false);

-- -----------------------------------------------------------------------------
-- Frameworks and provisions
-- -----------------------------------------------------------------------------
insert into ref.framework (code, title, issuer, framework_kind, edition, published_on, publication_url) values
('FATF_RECOMMENDATIONS',
 'International Standards on Combating Money Laundering and the Financing of Terrorism & Proliferation (The FATF Recommendations)',
 'Financial Action Task Force (FATF)', 'international_standard', '2012, as updated June 2025', date '2012-02-16',
 'https://www.fatf-gafi.org/en/publications/Fatfrecommendations/Fatf-recommendations.html'),
('EBA_GL_2021_02',
 'Guidelines on customer due diligence and the factors credit and financial institutions should consider when assessing the money laundering and terrorist financing risk associated with individual business relationships and occasional transactions (The ML/TF Risk Factors Guidelines)',
 'European Banking Authority (EBA)', 'supervisory_guideline', 'EBA/GL/2021/02, consolidated with EBA/GL/2023/03', date '2021-03-01',
 'https://www.eba.europa.eu/sites/default/files/document_library/Publications/Guidelines/2023/EBA-GL-2023-03/1061654/Guidelines%20ML%20TF%20Risk%20Factors_conslidated.pdf.pdf'),
('WOLFSBERG_RA_FAQ_2015',
 'The Wolfsberg Frequently Asked Questions on Risk Assessments for Money Laundering, Sanctions and Bribery & Corruption',
 'The Wolfsberg Group', 'industry_guidance', '2015', date '2015-09-08',
 'https://wolfsberg-group.org/resources/rba/29');

insert into ref.framework_provision (framework_code, provision_ref, heading, summary) values
('FATF_RECOMMENDATIONS', 'R.1', 'Assessing risks and applying a risk-based approach',
 'Countries and financial institutions should identify, assess and understand their ML/TF/PF risks and apply measures commensurate with them.'),
('FATF_RECOMMENDATIONS', 'INR.1', 'Interpretive Note to Recommendation 1: proliferation financing risk',
 'Proliferation financing risk refers strictly and only to the potential breach, non-implementation or evasion of the targeted financial sanctions obligations in Recommendation 7.'),
('FATF_RECOMMENDATIONS', 'R.3', 'Money laundering offence',
 'Money laundering is criminalised and applies to all serious offences, with a view to including the widest range of predicate offences.'),
('FATF_RECOMMENDATIONS', 'R.5', 'Terrorist financing offence',
 'Terrorist financing is criminalised, covering the financing of terrorist acts, terrorist organisations and individual terrorists, and is a predicate offence for money laundering.'),
('FATF_RECOMMENDATIONS', 'R.6', 'Targeted financial sanctions related to terrorism and terrorist financing',
 'Funds or other assets of designated persons and entities must be frozen without delay and no funds made available to them.'),
('FATF_RECOMMENDATIONS', 'R.7', 'Targeted financial sanctions related to proliferation',
 'Targeted financial sanctions implementing UN Security Council resolutions on the proliferation of weapons of mass destruction and its financing.'),
('FATF_RECOMMENDATIONS', 'R.15', 'New technologies',
 'Financial institutions should identify and assess ML/TF risks of (a) new products and new business practices, including new delivery mechanisms, and (b) new or developing technologies for new and pre-existing products, prior to launch, and take appropriate measures to manage and mitigate those risks.'),
('FATF_RECOMMENDATIONS', 'Glossary: designated categories of offences', 'Designated categories of offences',
 'The 21 categories of offences that each country must cover as money laundering predicate offences.'),

('EBA_GL_2021_02', '1.22', 'Risk factors for individual risk assessments',
 'Firms should consider who the customer is, the countries or geographical areas they operate in, the products, services and transactions required, and the delivery channels used.'),
('EBA_GL_2021_02', 'Guideline 2: Customer risk factors', 'Customer risk factors',
 'Risk related to the customer''s and beneficial owner''s business or professional activity, reputation, and nature and behaviour, including indicators of increased TF risk.'),
('EBA_GL_2021_02', 'Guideline 2: Countries and geographical areas', 'Countries and geographical areas',
 'Risk related to jurisdictions of residence, business and links; assessed through the effectiveness of the AML/CFT regime, TF risk and sanctions, tax transparency and compliance, and the level of predicate offences.'),
('EBA_GL_2021_02', 'Guideline 2: Products, services and transactions risk factors', 'Products, services and transactions risk factors',
 'Risk related to the transparency or opaqueness, complexity (including new or innovative products and technologies) and value or size of the product, service or transaction.'),
('EBA_GL_2021_02', 'Guideline 2: Delivery channel risk factors', 'Delivery channel risk factors',
 'Risk related to non-face-to-face business and to introducers, intermediaries, agents and outsourced service providers.'),

('WOLFSBERG_RA_FAQ_2015', '6', 'Risk assessment methodology',
 'Three phases: determine the inherent risk; assess the internal control environment (design and operating effectiveness); derive the residual risk.'),
('WOLFSBERG_RA_FAQ_2015', '6.1', 'Phase 1: Inherent risk assessment',
 'Inherent risk is exposure to money laundering, sanctions or bribery and corruption risk absent controls, assessed across clients, products and services, channels, geographies and other qualitative risk factors.'),
('WOLFSBERG_RA_FAQ_2015', '6.1.5', 'Other qualitative risk factors',
 'Factors such as new products or services, acquisitions, new locations, reliance on third-party providers, IT integration, client growth and AML staff turnover that can change inherent risk or strain controls.'),
('WOLFSBERG_RA_FAQ_2015', '6.2', 'Phase 2: Assessment of internal controls',
 'Controls are assessed by category for design and operating effectiveness, e.g. satisfactory / needs improvement / deficient. A remediation action is not in itself a mitigating factor.'),
('WOLFSBERG_RA_FAQ_2015', '6.2.1', 'AML Unit override',
 'Inherent or control ratings may be overridden; the rationale must be documented, supported and approved by someone with appropriate authority.'),
('WOLFSBERG_RA_FAQ_2015', '6.3', 'Phase 3: Arriving at the residual risk',
 'Residual risk is the risk that remains after controls are applied to inherent risk, e.g. on a High / Moderate / Low scale. A High inherent risk can never achieve a Low residual risk.');

-- -----------------------------------------------------------------------------
-- Seeding helper
--   terms: [{code, label, description?, parent?, scheme?, ext?, attributes?,
--            basis?: [[framework_code, provision_ref, relationship, note?], ...]}]
-- -----------------------------------------------------------------------------
create function pg_temp.seed_taxonomy(
    p_code           text,
    p_name           text,
    p_description    text,
    p_hierarchical   boolean,
    p_requires_basis boolean,
    p_terms          jsonb
) returns void
    language plpgsql
as $$
declare
    v_version_id uuid;
    v_term_id    uuid;
    v_term       jsonb;
    v_basis      jsonb;
    v_prov_id    uuid;
    v_ordinal    integer := 0;
begin
    insert into ref.taxonomy (code, name, description, is_hierarchical, requires_framework_basis)
    values (p_code, p_name, p_description, p_hierarchical, p_requires_basis);

    insert into ref.taxonomy_version (taxonomy_code, owner_id, origin, change_reason)
    values (p_code, 'role:fcrm-reference-data-steward', 'reference_data_seed', 'Initial load')
    returning id into v_version_id;

    for v_term in select value from jsonb_array_elements(p_terms) loop
        v_ordinal := v_ordinal + 10;

        if v_term ? 'parent' and not exists (
            select 1 from ref.taxonomy_term t
             where t.taxonomy_version_id = v_version_id and t.term_code = v_term ->> 'parent') then
            raise exception 'seed %: parent % of % not found', p_code, v_term ->> 'parent', v_term ->> 'code';
        end if;

        insert into ref.taxonomy_term (
            taxonomy_version_id, term_code, label, description, parent_term_id,
            sort_order, external_scheme, external_code, attributes)
        values (
            v_version_id,
            v_term ->> 'code',
            v_term ->> 'label',
            v_term ->> 'description',
            (select t.id from ref.taxonomy_term t
              where t.taxonomy_version_id = v_version_id and t.term_code = v_term ->> 'parent'),
            v_ordinal,
            v_term ->> 'scheme',
            v_term ->> 'ext',
            coalesce(v_term -> 'attributes', '{}'))
        returning id into v_term_id;

        for v_basis in select value from jsonb_array_elements(coalesce(v_term -> 'basis', '[]')) loop
            select id into v_prov_id from ref.framework_provision
             where framework_code = v_basis ->> 0 and provision_ref = v_basis ->> 1;
            if v_prov_id is null then
                raise exception 'seed %: provision %/% not found', p_code, v_basis ->> 0, v_basis ->> 1;
            end if;
            insert into ref.taxonomy_term_basis (taxonomy_version_id, taxonomy_term_id, framework_provision_id, relationship, note)
            values (v_version_id, v_term_id, v_prov_id, (v_basis ->> 2)::ref.basis_relationship, v_basis ->> 3);
        end loop;
    end loop;

    update ref.taxonomy_version set record_status = 'active' where id = v_version_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grounded taxonomies
-- -----------------------------------------------------------------------------
select pg_temp.seed_taxonomy('CHANGE_REQUEST_TYPE', 'Change request type',
    'Kind of change that must be risk-assessed before launch (FATF R.15). Drives the intake questionnaire and routing.', false, true,
    '[
      {"code": "PRODUCT", "label": "New product",
       "description": "Launch of a new product or service.",
       "basis": [["FATF_RECOMMENDATIONS", "R.15", "defined_by", "(a) new products"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1.5", "aligned_with", "introduction of new products and/or services"]]},
      {"code": "FEATURE", "label": "Product feature or technology change",
       "description": "Material change to an existing product, including use of new or developing technology.",
       "basis": [["FATF_RECOMMENDATIONS", "R.15", "defined_by", "(b) new or developing technologies for pre-existing products"],
                 ["EBA_GL_2021_02", "Guideline 2: Products, services and transactions risk factors", "derived_from", "complexity: new or innovative products and technologies"]]},
      {"code": "DELIVERY_CHANNEL", "label": "New or changed delivery mechanism",
       "description": "New or materially changed way customers obtain the product or service.",
       "basis": [["FATF_RECOMMENDATIONS", "R.15", "defined_by", "(a) new delivery mechanisms"],
                 ["EBA_GL_2021_02", "Guideline 2: Delivery channel risk factors", "derived_from"]]},
      {"code": "PROCESS", "label": "New or changed business practice",
       "description": "Change to an operational or customer process.",
       "basis": [["FATF_RECOMMENDATIONS", "R.15", "defined_by", "(a) new business practices"]]},
      {"code": "VENDOR", "label": "Third party, introducer or outsourced provider",
       "description": "Onboarding or material change of reliance on a third party.",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1.5", "derived_from", "reliance on third party providers"],
                 ["EBA_GL_2021_02", "Guideline 2: Delivery channel risk factors", "derived_from", "introducers, intermediaries, outsourced service providers"]]},
      {"code": "GEOGRAPHY", "label": "New geography",
       "description": "Entry into a new country or market.",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1.5", "derived_from", "opening in a new location"],
                 ["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "derived_from"]]},
      {"code": "SEGMENT", "label": "New customer segment",
       "description": "Serving a new customer segment or type.",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Customer risk factors", "derived_from"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1", "derived_from", "clients"]]}
    ]');

select pg_temp.seed_taxonomy('RISK_FACTOR_CATEGORY', 'Risk factor category',
    'Decomposition of inherent ML/TF risk into categories and sub-factors, per EBA/GL/2021/02 Guideline 2 and Wolfsberg FAQs 6.1. '
    'Transaction risk sits under products, services and transactions, as in both sources.', true, true,
    '[
      {"code": "CUSTOMER", "label": "Customer risk",
       "basis": [["EBA_GL_2021_02", "1.22", "defined_by"], ["EBA_GL_2021_02", "Guideline 2: Customer risk factors", "defined_by"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by", "clients"]]},
      {"code": "CUSTOMER_ACTIVITY", "label": "Business or professional activity", "parent": "CUSTOMER",
       "description": "Sectors with higher corruption or ML/TF risk, cash intensity, PEP links, purpose of legal persons, consistency of background.",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Customer risk factors", "defined_by"]]},
      {"code": "CUSTOMER_REPUTATION", "label": "Reputation", "parent": "CUSTOMER",
       "description": "Adverse media, asset freezes, prior suspicious transaction reports, in-house integrity information.",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Customer risk factors", "defined_by"]]},
      {"code": "CUSTOMER_NATURE_BEHAVIOUR", "label": "Nature and behaviour", "parent": "CUSTOMER",
       "description": "Identity doubts, opaque ownership, unusual transactions, secrecy, source of funds/wealth, TF indicators.",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Customer risk factors", "defined_by"]]},

      {"code": "GEOGRAPHY", "label": "Country and geographic risk",
       "basis": [["EBA_GL_2021_02", "1.22", "defined_by"], ["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "defined_by"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by", "geographies"]]},
      {"code": "GEO_AML_CFT_REGIME", "label": "Effectiveness of the AML/CFT regime", "parent": "GEOGRAPHY",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "defined_by"]]},
      {"code": "GEO_TF_SANCTIONS", "label": "Terrorist financing and sanctions exposure", "parent": "GEOGRAPHY",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "defined_by"], ["FATF_RECOMMENDATIONS", "R.6", "aligned_with"],
                 ["FATF_RECOMMENDATIONS", "R.7", "aligned_with"]]},
      {"code": "GEO_TAX_TRANSPARENCY", "label": "Tax transparency and compliance", "parent": "GEOGRAPHY",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "defined_by"]]},
      {"code": "GEO_PREDICATE_OFFENCES", "label": "Level of predicate offences", "parent": "GEOGRAPHY",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Countries and geographical areas", "defined_by"]]},

      {"code": "PRODUCT_SERVICE_TRANSACTION", "label": "Product, service and transaction risk",
       "basis": [["EBA_GL_2021_02", "1.22", "defined_by"], ["EBA_GL_2021_02", "Guideline 2: Products, services and transactions risk factors", "defined_by"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by", "products and services"]]},
      {"code": "PST_TRANSPARENCY", "label": "Transparency or opaqueness", "parent": "PRODUCT_SERVICE_TRANSACTION",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Products, services and transactions risk factors", "defined_by"]]},
      {"code": "PST_COMPLEXITY", "label": "Complexity, including new technology", "parent": "PRODUCT_SERVICE_TRANSACTION",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Products, services and transactions risk factors", "defined_by"], ["FATF_RECOMMENDATIONS", "R.15", "aligned_with"]]},
      {"code": "PST_VALUE_SIZE", "label": "Value or size, including cash intensity", "parent": "PRODUCT_SERVICE_TRANSACTION",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Products, services and transactions risk factors", "defined_by"]]},

      {"code": "DELIVERY_CHANNEL", "label": "Delivery channel risk",
       "basis": [["EBA_GL_2021_02", "1.22", "defined_by"], ["EBA_GL_2021_02", "Guideline 2: Delivery channel risk factors", "defined_by"],
                 ["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by", "channels"]]},
      {"code": "CHANNEL_NON_FACE_TO_FACE", "label": "Non-face-to-face business", "parent": "DELIVERY_CHANNEL",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Delivery channel risk factors", "defined_by"]]},
      {"code": "CHANNEL_INTERMEDIARIES", "label": "Introducers, intermediaries, agents and outsourcing", "parent": "DELIVERY_CHANNEL",
       "basis": [["EBA_GL_2021_02", "Guideline 2: Delivery channel risk factors", "defined_by"]]},

      {"code": "OTHER_QUALITATIVE", "label": "Other qualitative risk factors",
       "description": "Change-driven factors that alter inherent risk or strain controls; central to new-product assessments.",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by"], ["WOLFSBERG_RA_FAQ_2015", "6.1.5", "defined_by"]]},
      {"code": "OQ_CHANGE_GROWTH", "label": "New products, locations, acquisitions and growth", "parent": "OTHER_QUALITATIVE",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1.5", "defined_by"]]},
      {"code": "OQ_THIRD_PARTY_RELIANCE", "label": "Reliance on third-party providers", "parent": "OTHER_QUALITATIVE",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1.5", "defined_by"]]},
      {"code": "OQ_OPERATIONAL_CAPACITY", "label": "IT integration, AML staffing and remediation load", "parent": "OTHER_QUALITATIVE",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1.5", "defined_by"]]}
    ]');

select pg_temp.seed_taxonomy('RISK_TYPOLOGY', 'Financial crime risk typology',
    'Financial-crime risks a change may expose the bank to. Money-laundering predicates are the FATF designated categories of offences.', true, true,
    '[
      {"code": "ML", "label": "Money laundering",
       "basis": [["FATF_RECOMMENDATIONS", "R.3", "defined_by"], ["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by"]]},
      {"code": "PRED_ORGANISED_CRIME",      "parent": "ML", "label": "Participation in an organised criminal group and racketeering", "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_TERRORISM",            "parent": "ML", "label": "Terrorism, including terrorist financing",                     "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_HUMAN_TRAFFICKING",    "parent": "ML", "label": "Trafficking in human beings and migrant smuggling",            "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_SEXUAL_EXPLOITATION",  "parent": "ML", "label": "Sexual exploitation, including sexual exploitation of children", "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_NARCOTICS",            "parent": "ML", "label": "Illicit trafficking in narcotic drugs and psychotropic substances", "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_ARMS",                 "parent": "ML", "label": "Illicit arms trafficking",                                     "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_STOLEN_GOODS",         "parent": "ML", "label": "Illicit trafficking in stolen and other goods",                "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_CORRUPTION",           "parent": "ML", "label": "Corruption and bribery",                                       "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_FRAUD",                "parent": "ML", "label": "Fraud",                                                        "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_COUNTERFEIT_CURRENCY", "parent": "ML", "label": "Counterfeiting currency",                                      "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_COUNTERFEIT_PRODUCTS", "parent": "ML", "label": "Counterfeiting and piracy of products",                        "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_ENVIRONMENTAL",        "parent": "ML", "label": "Environmental crime",                                          "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_MURDER_INJURY",        "parent": "ML", "label": "Murder, grievous bodily injury",                               "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_KIDNAPPING",           "parent": "ML", "label": "Kidnapping, illegal restraint and hostage-taking",             "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_ROBBERY_THEFT",        "parent": "ML", "label": "Robbery or theft",                                             "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_SMUGGLING",            "parent": "ML", "label": "Smuggling, including customs and excise duties and taxes",     "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_TAX_CRIMES",           "parent": "ML", "label": "Tax crimes (direct and indirect taxes)",                       "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_EXTORTION",            "parent": "ML", "label": "Extortion",                                                    "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_FORGERY",              "parent": "ML", "label": "Forgery",                                                      "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_PIRACY",               "parent": "ML", "label": "Piracy",                                                       "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "PRED_MARKET_ABUSE",         "parent": "ML", "label": "Insider trading and market manipulation",                      "basis": [["FATF_RECOMMENDATIONS", "Glossary: designated categories of offences", "defined_by"]]},
      {"code": "TF", "label": "Terrorist financing",
       "basis": [["FATF_RECOMMENDATIONS", "R.5", "defined_by"]]},
      {"code": "TFS_TERRORISM", "label": "Breach or evasion of terrorism-related targeted financial sanctions",
       "basis": [["FATF_RECOMMENDATIONS", "R.6", "defined_by"], ["WOLFSBERG_RA_FAQ_2015", "6.1", "aligned_with", "sanctions risk"]]},
      {"code": "PF", "label": "Proliferation financing (breach, non-implementation or evasion of PF targeted financial sanctions)",
       "basis": [["FATF_RECOMMENDATIONS", "R.7", "defined_by"], ["FATF_RECOMMENDATIONS", "INR.1", "defined_by"]]},
      {"code": "BRIBERY_CORRUPTION", "label": "Bribery and corruption",
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.1", "defined_by"]]}
    ]');

select pg_temp.seed_taxonomy('CONTROL_CATEGORY', 'Control category',
    'Categories across which financial-crime controls are assessed.', false, true,
    '[
      {"code": "GOVERNANCE",             "label": "Corporate governance, management oversight and accountability", "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "POLICIES_PROCEDURES",    "label": "Policies and procedures",                                        "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "KYC_CDD_EDD",            "label": "Know your client, client due diligence, enhanced due diligence",  "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "RISK_ASSESSMENTS",       "label": "Previous and other risk assessments",                            "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "MANAGEMENT_INFORMATION", "label": "Management information and reporting",                           "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "RECORD_KEEPING",         "label": "Record keeping and retention",                                   "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "COMPLIANCE_OFFICER",     "label": "Designated compliance officer or unit",                          "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "DETECTION_SAR",          "label": "Detection and suspicious activity reporting",                    "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "MONITORING_CONTROLS",    "label": "Monitoring and controls",                                        "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "TRAINING",               "label": "Training",                                                       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "INDEPENDENT_TESTING",    "label": "Independent testing and oversight",                              "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "OTHER",                  "label": "Other controls",                                                 "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]}
    ]');

select pg_temp.seed_taxonomy('CONTROL_EFFECTIVENESS', 'Control effectiveness',
    'Assessed design or operating effectiveness of a control. How much each level offsets inherent risk is set in scoring configuration, always below 100%.', false, true,
    '[
      {"code": "SATISFACTORY",      "label": "Satisfactory",      "attributes": {"ordinal": 1}, "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "NEEDS_IMPROVEMENT", "label": "Needs improvement", "attributes": {"ordinal": 2}, "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]},
      {"code": "DEFICIENT",         "label": "Deficient",
       "description": "Not designed or not operating effectively, untested, or absent. Planned remediation does not change this rating.",
       "attributes": {"ordinal": 3}, "basis": [["WOLFSBERG_RA_FAQ_2015", "6.2", "defined_by"]]}
    ]');

select pg_temp.seed_taxonomy('RATING_LEVEL', 'Risk rating level',
    'Inherent and residual risk levels. min_residual_ordinal is the lowest residual level each inherent level may reach: controls mitigate but never eliminate risk.', false, true,
    '[
      {"code": "LOW",      "label": "Low",      "attributes": {"ordinal": 1, "min_residual_ordinal": 1},
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.3", "defined_by"]]},
      {"code": "MODERATE", "label": "Moderate", "attributes": {"ordinal": 2, "min_residual_ordinal": 1},
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.3", "defined_by"]]},
      {"code": "HIGH",     "label": "High",     "attributes": {"ordinal": 3, "min_residual_ordinal": 2},
       "basis": [["WOLFSBERG_RA_FAQ_2015", "6.3", "defined_by", "A High inherent risk can never achieve a Low residual risk"]]}
    ]');

-- -----------------------------------------------------------------------------
-- Internal classifications (no framework basis required)
-- -----------------------------------------------------------------------------
select pg_temp.seed_taxonomy('GEOGRAPHY', 'Geography',
    'Regions (UN M49) and countries (ISO 3166-1 alpha-2). Public reference codes; country risk scores live in scoring configuration.', true, false,
    '[
      {"code": "REGION_AFRICA",   "label": "Africa",   "scheme": "UN-M49", "ext": "002"},
      {"code": "REGION_AMERICAS", "label": "Americas", "scheme": "UN-M49", "ext": "019"},
      {"code": "REGION_ASIA",     "label": "Asia",     "scheme": "UN-M49", "ext": "142"},
      {"code": "REGION_EUROPE",   "label": "Europe",   "scheme": "UN-M49", "ext": "150"},
      {"code": "REGION_OCEANIA",  "label": "Oceania",  "scheme": "UN-M49", "ext": "009"},
      {"code": "NG", "label": "Nigeria",              "parent": "REGION_AFRICA",   "scheme": "ISO3166-1-A2", "ext": "NG"},
      {"code": "KE", "label": "Kenya",                "parent": "REGION_AFRICA",   "scheme": "ISO3166-1-A2", "ext": "KE"},
      {"code": "ZA", "label": "South Africa",         "parent": "REGION_AFRICA",   "scheme": "ISO3166-1-A2", "ext": "ZA"},
      {"code": "BR", "label": "Brazil",               "parent": "REGION_AMERICAS", "scheme": "ISO3166-1-A2", "ext": "BR"},
      {"code": "CA", "label": "Canada",               "parent": "REGION_AMERICAS", "scheme": "ISO3166-1-A2", "ext": "CA"},
      {"code": "MX", "label": "Mexico",               "parent": "REGION_AMERICAS", "scheme": "ISO3166-1-A2", "ext": "MX"},
      {"code": "US", "label": "United States",        "parent": "REGION_AMERICAS", "scheme": "ISO3166-1-A2", "ext": "US"},
      {"code": "AE", "label": "United Arab Emirates", "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "AE"},
      {"code": "CN", "label": "China",                "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "CN"},
      {"code": "HK", "label": "Hong Kong",            "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "HK"},
      {"code": "IN", "label": "India",                "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "IN"},
      {"code": "IR", "label": "Iran",                 "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "IR"},
      {"code": "JP", "label": "Japan",                "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "JP"},
      {"code": "KP", "label": "North Korea",          "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "KP"},
      {"code": "MM", "label": "Myanmar",              "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "MM"},
      {"code": "PH", "label": "Philippines",          "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "PH"},
      {"code": "SG", "label": "Singapore",            "parent": "REGION_ASIA",     "scheme": "ISO3166-1-A2", "ext": "SG"},
      {"code": "CH", "label": "Switzerland",          "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "CH"},
      {"code": "DE", "label": "Germany",              "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "DE"},
      {"code": "FR", "label": "France",               "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "FR"},
      {"code": "GB", "label": "United Kingdom",       "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "GB"},
      {"code": "IE", "label": "Ireland",              "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "IE"},
      {"code": "LU", "label": "Luxembourg",           "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "LU"},
      {"code": "NL", "label": "Netherlands",          "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "NL"},
      {"code": "RU", "label": "Russia",               "parent": "REGION_EUROPE",   "scheme": "ISO3166-1-A2", "ext": "RU"},
      {"code": "AU", "label": "Australia",            "parent": "REGION_OCEANIA",  "scheme": "ISO3166-1-A2", "ext": "AU"},
      {"code": "NZ", "label": "New Zealand",          "parent": "REGION_OCEANIA",  "scheme": "ISO3166-1-A2", "ext": "NZ"}
    ]');

select pg_temp.seed_taxonomy('CUSTOMER_SEGMENT', 'Customer segment',
    'Customer populations a product or change serves (internal classification).', true, false,
    '[
      {"code": "RETAIL",                "label": "Retail"},
      {"code": "RETAIL_MASS",           "label": "Mass retail",                     "parent": "RETAIL"},
      {"code": "RETAIL_PRIVATE",        "label": "Private banking and wealth",      "parent": "RETAIL"},
      {"code": "BUSINESS",              "label": "Business"},
      {"code": "BUSINESS_SME",          "label": "Small and medium enterprises",    "parent": "BUSINESS"},
      {"code": "BUSINESS_CORPORATE",    "label": "Corporate and commercial",        "parent": "BUSINESS"},
      {"code": "FINANCIAL_INSTITUTION", "label": "Financial institutions"},
      {"code": "FI_CORRESPONDENT",      "label": "Correspondent banks",             "parent": "FINANCIAL_INSTITUTION"},
      {"code": "FI_NBFI",               "label": "Non-bank financial institutions", "parent": "FINANCIAL_INSTITUTION"},
      {"code": "FI_MSB",                "label": "Money service businesses",        "parent": "FINANCIAL_INSTITUTION"},
      {"code": "FI_VASP",               "label": "Virtual asset service providers", "parent": "FINANCIAL_INSTITUTION"},
      {"code": "PUBLIC_SECTOR",         "label": "Public sector and government"},
      {"code": "NON_PROFIT",            "label": "Non-profit organisations and charities"}
    ]');

select pg_temp.seed_taxonomy('CHANNEL', 'Delivery channel',
    'How customers are onboarded or transact (internal classification; risk sub-factors are in RISK_FACTOR_CATEGORY).', false, false,
    '[
      {"code": "BRANCH",         "label": "Branch",                     "attributes": {"face_to_face": true}},
      {"code": "RELATIONSHIP",   "label": "Relationship manager",       "attributes": {"face_to_face": true}},
      {"code": "ONLINE",         "label": "Online banking",             "attributes": {"face_to_face": false}},
      {"code": "MOBILE",         "label": "Mobile app",                 "attributes": {"face_to_face": false}},
      {"code": "CONTACT_CENTRE", "label": "Contact centre",             "attributes": {"face_to_face": false}},
      {"code": "INTERMEDIARY",   "label": "Introducer or intermediary", "attributes": {"face_to_face": false}},
      {"code": "API_PARTNER",    "label": "API / embedded partner",     "attributes": {"face_to_face": false}},
      {"code": "ATM",            "label": "ATM and self-service",       "attributes": {"face_to_face": false}}
    ]');

select pg_temp.seed_taxonomy('PRODUCT_CATEGORY', 'Product category',
    'Families of products and services (internal classification).', true, false,
    '[
      {"code": "DEPOSITS",               "label": "Deposits and accounts"},
      {"code": "LENDING",                "label": "Lending"},
      {"code": "CARDS",                  "label": "Cards"},
      {"code": "PAYMENTS",               "label": "Payments"},
      {"code": "PAYMENTS_DOMESTIC",      "label": "Domestic payments",     "parent": "PAYMENTS"},
      {"code": "PAYMENTS_CROSS_BORDER",  "label": "Cross-border payments", "parent": "PAYMENTS"},
      {"code": "TRADE_FINANCE",          "label": "Trade finance"},
      {"code": "WEALTH_INVESTMENT",      "label": "Wealth and investment"},
      {"code": "CORRESPONDENT_SERVICES", "label": "Correspondent banking services"},
      {"code": "DIGITAL_ASSETS",         "label": "Digital assets"}
    ]');

select pg_temp.seed_taxonomy('CONTROL_TYPE', 'Control type',
    'When a control acts relative to the risk event (internal classification).', false, false,
    '[
      {"code": "PREVENTIVE", "label": "Preventive"},
      {"code": "DETECTIVE",  "label": "Detective"},
      {"code": "CORRECTIVE", "label": "Corrective"}
    ]');

select pg_temp.seed_taxonomy('CONTROL_NATURE', 'Control nature',
    'How a control is performed (internal classification).', false, false,
    '[
      {"code": "AUTOMATED",           "label": "Automated"},
      {"code": "IT_DEPENDENT_MANUAL", "label": "IT-dependent manual"},
      {"code": "MANUAL",              "label": "Manual"}
    ]');

select pg_temp.seed_taxonomy('DOCUMENT_TYPE', 'Document type',
    'Classification of submitted and corpus documents (internal classification).', false, false,
    '[
      {"code": "PRODUCT_SPECIFICATION", "label": "Product specification"},
      {"code": "BUSINESS_CASE",         "label": "Business case"},
      {"code": "PROCESS_MAP",           "label": "Process map or procedure"},
      {"code": "VENDOR_DUE_DILIGENCE",  "label": "Vendor due diligence"},
      {"code": "LEGAL_OPINION",         "label": "Legal or regulatory opinion"},
      {"code": "CONTROL_EVIDENCE",      "label": "Control test evidence"},
      {"code": "COMMITTEE_PACK",        "label": "Committee pack"},
      {"code": "POLICY_SOURCE",         "label": "Internal policy source document"},
      {"code": "REGULATORY_TEXT",       "label": "Regulatory text or guidance"},
      {"code": "OTHER",                 "label": "Other"}
    ]');

drop function pg_temp.seed_taxonomy(text, text, text, boolean, boolean, jsonb);

select set_config('fcrm.actor_id', '', false);
