public with sharing class TriageIntakeController {

    // ====================================================================
    // CONFIG — paste your Flex prompt template Id to enable Einstein.
    // Leave blank to use the built-in deterministic summary.
    // ====================================================================
    private static final String PROMPT_TEMPLATE_ID = '';
    private static final String PROMPT_INPUT_NAME   = 'Input:ClinicalContext';

    // ===================== DTOs (shared with the LWC) ====================
    public class SymptomOption {
        @AuraEnabled public String externalId;
        @AuraEnabled public String label;
        @AuraEnabled public String bodySystem;
    }
    public class MedInput {
        @AuraEnabled public String drugName;
        @AuraEnabled public String dosage;
        @AuraEnabled public String frequency;
    }
    public class IntakeRequest {
        @AuraEnabled public String patientFirstName;
        @AuraEnabled public String patientLastName;
        @AuraEnabled public String patientExternalId;
        @AuraEnabled public Integer durationDays;
        @AuraEnabled public String severity;
        @AuraEnabled public List<String> symptomExternalIds;
        @AuraEnabled public List<MedInput> medications;
        @AuraEnabled public List<String> priorObservations;
    }
    public class ConditionResult implements Comparable {
        @AuraEnabled public String externalId;
        @AuraEnabled public String name;
        @AuraEnabled public Integer score;
        @AuraEnabled public Integer rank;
        @AuraEnabled public Boolean isRedFlag;
        @AuraEnabled public String priority;
        @AuraEnabled public String specialty;
        @AuraEnabled public Id specialtyId;
        public Integer compareTo(Object o) {
            ConditionResult other = (ConditionResult) o;
            if (this.score < other.score) return 1;
            if (this.score > other.score) return -1;
            return this.name.compareTo(other.name);
        }
    }
    public class IntakeResult {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String triageLevel;
        @AuraEnabled public Boolean isRedFlag;
        @AuraEnabled public String recommendedSpecialty;
        @AuraEnabled public List<ConditionResult> probableConditions;
        @AuraEnabled public String aiSummary;
        @AuraEnabled public Boolean aiUsed;
        @AuraEnabled public String aiContext; // clinical context string, passed to GPT-5.6 by the LWC
    }

    // ===================== Load the symptom picklist =====================
    @AuraEnabled(cacheable=true)
    public static List<SymptomOption> getSymptoms() {
        List<SymptomOption> opts = new List<SymptomOption>();
        for (Symptom__c s : [
            SELECT External_Id__c, Name, Body_System__c
            FROM Symptom__c
            WHERE External_Id__c != null
            ORDER BY Body_System__c, Name
        ]) {
            SymptomOption o = new SymptomOption();
            o.externalId = s.External_Id__c;
            o.label = s.Name;
            o.bodySystem = (s.Body_System__c == null) ? 'Other' : s.Body_System__c;
            opts.add(o);
        }
        System.debug('TRIAGE getSymptoms -> returning ' + opts.size() + ' symptoms');
        return opts;
    }

    // ===================== JSON entry point (LWC calls THIS) =============
    // The LWC sends JSON.stringify(request) as a String. A String param
    // always transports cleanly; an inner-class param does not.
    @AuraEnabled
    public static IntakeResult submitIntakeJson(String payload) {
        if (String.isBlank(payload)) {
            throw new AuraHandledException('Please complete the intake form before submitting.');
        }

        try {
            IntakeRequest req = (IntakeRequest) JSON.deserialize(payload, IntakeRequest.class);
            System.debug('TRIAGE submitIntakeJson -> payload received');
            return submitIntake(req);
        } catch (System.JSONException e) {
            throw new AuraHandledException('The intake request could not be read. Please try again.');
        }
    }

    // ===================== Main intake logic ============================
    @AuraEnabled
    public static IntakeResult submitIntake(IntakeRequest req) {
        System.debug('TRIAGE submitIntake -> symptoms: ' +
            (req == null ? 'NULL REQ' : String.valueOf(req.symptomExternalIds)));

        if (req == null || req.symptomExternalIds == null || req.symptomExternalIds.isEmpty()) {
            throw new AuraHandledException('Please select at least one symptom.');
        }

        Set<String> symptomSet = new Set<String>();
        for (String symptomExternalId : req.symptomExternalIds) {
            if (String.isNotBlank(symptomExternalId)) {
                symptomSet.add(symptomExternalId);
            }
        }
        if (symptomSet.isEmpty()) {
            throw new AuraHandledException('Please select at least one symptom.');
        }

        Map<String, Symptom__c> symByExt = symptomsByExt(symptomSet);
        if (symByExt.size() != symptomSet.size()) {
            throw new AuraHandledException('Please select a valid symptom.');
        }

        List<ConditionResult> ranked = scoreConditions(symptomSet);
        System.debug('TRIAGE scoring -> ' + ranked.size() + ' conditions matched');

        String triage = 'Routine';
        Boolean redFlag = false;
        Id specialtyId = null;
        String specialtyName = null;
        if (!ranked.isEmpty()) {
            ConditionResult top = ranked[0];
            System.debug('TRIAGE top -> ' + top.name + ' (score ' + top.score + ', redFlag ' + top.isRedFlag + ')');
            redFlag = (top.isRedFlag == true);
            if (redFlag) {
                triage = 'Critical';
                Specialty__c em = resolveSpecialty('SPEC_EM');
                if (em != null) { specialtyId = em.Id; specialtyName = em.Name; }
            } else {
                triage = (top.priority == null) ? 'Routine' : top.priority;
                specialtyId = top.specialtyId;
                specialtyName = top.specialty;
            }
        }
        System.debug('TRIAGE decision -> ' + triage + ' | ' + specialtyName + ' | redFlag ' + redFlag);

        Contact patient = resolvePatient(req);
        String symptomLabel = buildSymptomLabel(symByExt);

        Case c = new Case(
            ContactId = patient.Id,
            Subject = 'Triage intake: ' + symptomLabel,
            Status = 'New',
            Origin = 'Web',
            Triage_Level__c = triage,
            Is_Red_Flag__c = redFlag,
            Recommended_Specialty__c = specialtyId,
            Description = 'Auto-intake. Severity: ' + req.severity + '. Duration: ' + req.durationDays + ' day(s).'
        );
        insert c;
        System.debug('TRIAGE created Case -> ' + c.Id);

        List<Case_Symptom__c> css = new List<Case_Symptom__c>();
        for (String ext : symptomSet) {
            Symptom__c s = symByExt.get(ext);
            if (s == null) continue;
            css.add(new Case_Symptom__c(
                Case__c = c.Id, Symptom__c = s.Id,
                Severity__c = req.severity, Duration_Days__c = req.durationDays));
        }
        if (!css.isEmpty()) insert css;
        System.debug('TRIAGE created ' + css.size() + ' Case_Symptom rows');

        List<Probable_Condition__c> pcs = new List<Probable_Condition__c>();
        Map<String, Id> condIdByExt = conditionIdsByExt(ranked);
        Integer limit3 = Math.min(3, ranked.size());
        for (Integer i = 0; i < limit3; i++) {
            ConditionResult r = ranked[i];
            pcs.add(new Probable_Condition__c(
                Case__c = c.Id, Condition__c = condIdByExt.get(r.externalId),
                Score__c = r.score, Rank__c = r.rank, Is_Red_Flag__c = r.isRedFlag));
        }
        if (!pcs.isEmpty()) insert pcs;
        System.debug('TRIAGE created ' + pcs.size() + ' Probable_Condition rows');

        saveHistory(req, patient.Id);

        String context = buildClinicalContext(req, symByExt, ranked, redFlag, patient.Id);
        Boolean usedAI = false;
        String summary;
        try {
            if (String.isNotBlank(PROMPT_TEMPLATE_ID)) {
                summary = callEinstein(context);
                usedAI = String.isNotBlank(summary);
            }
        } catch (Exception e) {
            System.debug('TRIAGE Einstein failed, fallback -> ' + e.getMessage());
            usedAI = false;
        }
        if (!usedAI) summary = fallbackSummary(ranked, redFlag, specialtyName);

        IntakeResult out = new IntakeResult();
        out.caseId = c.Id;
        out.triageLevel = triage;
        out.isRedFlag = redFlag;
        out.recommendedSpecialty = specialtyName;
        out.probableConditions = ranked;
        out.aiSummary = summary;
        out.aiUsed = usedAI;
        out.aiContext = context;
        System.debug('TRIAGE done -> Case ' + c.Id + ' | ' + triage + ' | ' + specialtyName);
        return out;
    }

    // ========================= scoring ===================================
    private static List<ConditionResult> scoreConditions(Set<String> symptomExtIds) {
        Map<String, Integer> scoreByCond = new Map<String, Integer>();
        for (Symptom_Condition_Map__c m : [
            SELECT Condition__r.External_Id__c, Weight__c
            FROM Symptom_Condition_Map__c
            WHERE Symptom__r.External_Id__c IN :symptomExtIds
              AND Condition__r.External_Id__c != null
        ]) {
            String key = m.Condition__r.External_Id__c;
            Integer cur = scoreByCond.containsKey(key) ? scoreByCond.get(key) : 0;
            scoreByCond.put(key, cur + (Integer) m.Weight__c);
        }
        List<ConditionResult> results = new List<ConditionResult>();
        if (scoreByCond.isEmpty()) return results;

        for (Condition__c cond : [
            SELECT External_Id__c, Name, Triage_Priority__c, Is_Red_Flag__c,
                   Recommended_Specialty__c, Recommended_Specialty__r.Name
            FROM Condition__c WHERE External_Id__c IN :scoreByCond.keySet()
        ]) {
            ConditionResult r = new ConditionResult();
            r.externalId = cond.External_Id__c;
            r.name = cond.Name;
            r.score = scoreByCond.get(cond.External_Id__c);
            r.isRedFlag = cond.Is_Red_Flag__c;
            r.priority = cond.Triage_Priority__c;
            r.specialty = cond.Recommended_Specialty__r.Name;
            r.specialtyId = cond.Recommended_Specialty__c;
            results.add(r);
        }
        results.sort();
        for (Integer i = 0; i < results.size(); i++) results[i].rank = i + 1;
        return results;
    }

    // ========================= helpers ===================================
    private static Contact resolvePatient(IntakeRequest req) {
        String first = String.isBlank(req.patientFirstName) ? 'Walk-in' : req.patientFirstName;
        String last  = String.isBlank(req.patientLastName)  ? 'Patient'  : req.patientLastName;
        String ext   = String.isBlank(req.patientExternalId)
                       ? 'PT_' + String.valueOf(DateTime.now().getTime())
                       : req.patientExternalId;
        Contact c = new Contact(FirstName = first, LastName = last, Patient_External_Id__c = ext);
        upsert c Patient_External_Id__c;
        return c;
    }

    private static void saveHistory(IntakeRequest req, Id patientId) {
        List<Patient_Medication__c> meds = new List<Patient_Medication__c>();
        if (req.medications != null) {
            for (MedInput m : req.medications) {
                if (String.isBlank(m.drugName)) continue;
                meds.add(new Patient_Medication__c(
                    Patient__c = patientId, Drug_Name__c = m.drugName,
                    Dosage__c = m.dosage, Frequency__c = m.frequency, Still_Taking__c = true));
            }
        }
        if (!meds.isEmpty()) insert meds;

        List<Prior_Observation__c> obs = new List<Prior_Observation__c>();
        if (req.priorObservations != null) {
            for (String o : req.priorObservations) {
                if (String.isBlank(o)) continue;
                obs.add(new Prior_Observation__c(
                    Patient__c = patientId, Condition_Or_Diagnosis__c = o.left(255),
                    Source__c = 'Patient-reported'));
            }
        }
        if (!obs.isEmpty()) insert obs;
    }

    private static Specialty__c resolveSpecialty(String ext) {
        List<Specialty__c> s = [SELECT Id, Name FROM Specialty__c WHERE External_Id__c = :ext LIMIT 1];
        return s.isEmpty() ? null : s[0];
    }
    private static Map<String, Symptom__c> symptomsByExt(Set<String> exts) {
        Map<String, Symptom__c> m = new Map<String, Symptom__c>();
        for (Symptom__c s : [SELECT Id, Name, External_Id__c FROM Symptom__c WHERE External_Id__c IN :exts]) {
            m.put(s.External_Id__c, s);
        }
        return m;
    }
    private static Map<String, Id> conditionIdsByExt(List<ConditionResult> ranked) {
        Set<String> exts = new Set<String>();
        for (ConditionResult r : ranked) exts.add(r.externalId);
        Map<String, Id> m = new Map<String, Id>();
        for (Condition__c c : [SELECT Id, External_Id__c FROM Condition__c WHERE External_Id__c IN :exts]) {
            m.put(c.External_Id__c, c.Id);
        }
        return m;
    }
    private static String buildSymptomLabel(Map<String, Symptom__c> symptomsByExternalId) {
        List<String> names = new List<String>();
        for (Symptom__c s : symptomsByExternalId.values()) names.add(s.Name);
        String joined = String.join(names, ', ');
        return joined.length() > 200 ? joined.left(197) + '...' : joined;
    }

    private static String buildClinicalContext(IntakeRequest req, Map<String, Symptom__c> symByExt,
            List<ConditionResult> ranked, Boolean redFlag, Id patientId) {
        List<String> symNames = new List<String>();
        for (Symptom__c s : symByExt.values()) symNames.add(s.Name);
        List<String> condLines = new List<String>();
        Integer lim = Math.min(3, ranked.size());
        for (Integer i = 0; i < lim; i++) {
            ConditionResult r = ranked[i];
            condLines.add((i + 1) + '. ' + r.name + ' (score ' + r.score + ', '
                + r.priority + (r.isRedFlag ? ', RED FLAG' : '') + ')');
        }
        List<String> medLines = new List<String>();
        if (req.medications != null) {
            for (MedInput m : req.medications) {
                if (String.isBlank(m.drugName)) continue;
                medLines.add(m.drugName + ' ' + m.dosage + ' ' + m.frequency);
            }
        }
        for (Patient_Medication__c pm : [SELECT Drug_Name__c, Dosage__c, Frequency__c
                FROM Patient_Medication__c WHERE Patient__c = :patientId AND Still_Taking__c = true]) {
            medLines.add(pm.Drug_Name__c + ' ' + pm.Dosage__c + ' ' + pm.Frequency__c);
        }
        List<String> allergyLines = new List<String>();
        for (Allergy__c a : [SELECT Allergen__c, Reaction__c, Severity__c
                FROM Allergy__c WHERE Patient__c = :patientId]) {
            allergyLines.add(a.Allergen__c + ' (' + a.Severity__c + ' - ' + a.Reaction__c + ')');
        }
        List<String> histLines = new List<String>();
        if (req.priorObservations != null) for (String o : req.priorObservations) if (String.isNotBlank(o)) histLines.add(o);
        for (Prior_Observation__c po : [SELECT Condition_Or_Diagnosis__c, Diagnosed_By__c
                FROM Prior_Observation__c WHERE Patient__c = :patientId]) {
            histLines.add(po.Condition_Or_Diagnosis__c + (po.Diagnosed_By__c != null ? ' (per ' + po.Diagnosed_By__c + ')' : ''));
        }
        String ctx = 'PATIENT PRESENTATION (for clinician review)\n';
        ctx += 'Symptoms reported: ' + String.join(symNames, ', ') + '\n';
        ctx += 'Duration: ' + req.durationDays + ' day(s). Self-rated severity: ' + req.severity + '\n';
        ctx += 'Rule-based probable issues (ranked):\n' + String.join(condLines, '\n') + '\n';
        ctx += 'Red-flag pattern detected: ' + (redFlag ? 'YES - recommend immediate escalation' : 'no') + '\n';
        ctx += 'Current medications: ' + (medLines.isEmpty() ? 'none reported' : String.join(medLines, '; ')) + '\n';
        ctx += 'Known allergies: ' + (allergyLines.isEmpty() ? 'none on file' : String.join(allergyLines, '; ')) + '\n';
        ctx += 'Prior history: ' + (histLines.isEmpty() ? 'none reported' : String.join(histLines, '; ')) + '\n';
        return ctx;
    }

    private static String callEinstein(String context) {
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = context;
        Map<String, ConnectApi.WrappedValue> inputs = new Map<String, ConnectApi.WrappedValue>();
        inputs.put(PROMPT_INPUT_NAME, wv);
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = inputs;
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'TriageIntake';
        input.additionalConfig.numGenerations = 1;
        input.additionalConfig.enablePiiMasking = false;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation out =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_ID, input);
        if (out != null && out.generations != null && !out.generations.isEmpty()) {
            return out.generations[0].text;
        }
        return null;
    }

    private static String fallbackSummary(List<ConditionResult> ranked, Boolean redFlag, String specialty) {
        String s = '';
        if (redFlag) {
            s += '\u26A0 RED-FLAG PATTERN. Recommend immediate escalation to Emergency Medicine before anything else.\n\n';
        }
        s += 'For clinician review (decision support, not a diagnosis):\n';
        Integer lim = Math.min(3, ranked.size());
        if (lim == 0) { s += 'No conditions matched the selected symptoms.'; return s; }
        s += 'Based on a rule-based match of the reported symptoms, the most likely issues to consider are: ';
        List<String> parts = new List<String>();
        for (Integer i = 0; i < lim; i++) parts.add(ranked[i].name + ' (score ' + ranked[i].score + ')');
        s += String.join(parts, '; ') + '.\n';
        if (String.isNotBlank(specialty)) s += 'Suggested routing: ' + specialty + ' (for clinician confirmation).';
        return s;
    }
}
