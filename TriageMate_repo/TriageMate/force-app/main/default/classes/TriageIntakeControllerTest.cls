@IsTest
private class TriageIntakeControllerTest {
    private static final String SPEC_GP = 'SPEC_GP_TEST';
    private static final String SPEC_EM = 'SPEC_EM';
    private static final String SYM_FEVER = 'SYM_FEVER_TEST';
    private static final String SYM_CHEST = 'SYM_CHEST_TEST';
    private static final String CON_FLU = 'CON_FLU_TEST';
    private static final String CON_ACS = 'CON_ACS_TEST';

    @TestSetup
    static void makeData() {
        Specialty__c primaryCare = new Specialty__c(
            Name = 'General Medicine Test',
            External_Id__c = SPEC_GP
        );
        Specialty__c emergencyMedicine = new Specialty__c(
            Name = 'Emergency Medicine',
            External_Id__c = SPEC_EM
        );
        insert new List<Specialty__c>{ primaryCare, emergencyMedicine };

        Symptom__c fever = new Symptom__c(
            Name = 'Fever Test',
            External_Id__c = SYM_FEVER,
            Body_System__c = 'General'
        );
        Symptom__c chestPain = new Symptom__c(
            Name = 'Chest Pain Test',
            External_Id__c = SYM_CHEST,
            Body_System__c = 'Cardiovascular'
        );
        insert new List<Symptom__c>{ fever, chestPain };

        Condition__c flu = new Condition__c(
            Name = 'Influenza Test',
            External_Id__c = CON_FLU,
            Triage_Priority__c = 'Urgent',
            Is_Red_Flag__c = false,
            Recommended_Specialty__c = primaryCare.Id
        );
        Condition__c acs = new Condition__c(
            Name = 'Acute Coronary Syndrome Test',
            External_Id__c = CON_ACS,
            Triage_Priority__c = 'Critical',
            Is_Red_Flag__c = true,
            Recommended_Specialty__c = emergencyMedicine.Id
        );
        insert new List<Condition__c>{ flu, acs };

        insert new List<Symptom_Condition_Map__c>{
            new Symptom_Condition_Map__c(Symptom__c = fever.Id, Condition__c = flu.Id, Weight__c = 4),
            new Symptom_Condition_Map__c(Symptom__c = chestPain.Id, Condition__c = acs.Id, Weight__c = 5)
        };
    }

    @IsTest
    static void getSymptomsReturnsConfiguredOptions() {
        Test.startTest();
        List<TriageIntakeController.SymptomOption> symptoms = TriageIntakeController.getSymptoms();
        Test.stopTest();

        Set<String> externalIds = new Set<String>();
        for (TriageIntakeController.SymptomOption symptom : symptoms) {
            externalIds.add(symptom.externalId);
        }

        System.assert(externalIds.contains(SYM_FEVER), 'Expected configured fever symptom.');
        System.assert(externalIds.contains(SYM_CHEST), 'Expected configured chest-pain symptom.');
    }

    @IsTest
    static void submitIntakeJsonCreatesRoutineRecordsAndFallbackSummary() {
        TriageIntakeController.IntakeRequest request = new TriageIntakeController.IntakeRequest();
        request.patientFirstName = 'Alex';
        request.patientLastName = 'Rivera';
        request.patientExternalId = 'PAT_TEST_ROUTINE';
        request.durationDays = 3;
        request.severity = 'Moderate';
        request.symptomExternalIds = new List<String>{ SYM_FEVER };

        TriageIntakeController.MedInput med = new TriageIntakeController.MedInput();
        med.drugName = 'Acetaminophen';
        med.dosage = '500 mg';
        med.frequency = 'as needed';
        request.medications = new List<TriageIntakeController.MedInput>{ med };
        request.priorObservations = new List<String>{ 'Seasonal allergies' };

        Test.startTest();
        TriageIntakeController.IntakeResult result = TriageIntakeController.submitIntakeJson(JSON.serialize(request));
        Test.stopTest();

        System.assertNotEquals(null, result.caseId, 'Expected a Case id in the intake response.');
        System.assertEquals('Urgent', result.triageLevel, 'Expected top condition priority to drive triage level.');
        System.assertEquals(false, result.isRedFlag, 'Expected non-red-flag intake.');
        System.assertEquals(false, result.aiUsed, 'Expected deterministic fallback when no prompt template is configured.');
        System.assert(result.aiSummary.contains('Influenza Test'), 'Expected fallback summary to include the top condition.');

        Case createdCase = [SELECT Contact.Patient_External_Id__c, Subject, Triage_Level__c, Is_Red_Flag__c FROM Case WHERE Id = :result.caseId];
        System.assertEquals('PAT_TEST_ROUTINE', createdCase.Contact.Patient_External_Id__c);
        System.assert(createdCase.Subject.contains('Fever Test'), 'Expected Case subject to use the resolved symptom name.');
        System.assertEquals('Urgent', createdCase.Triage_Level__c);
        System.assertEquals(false, createdCase.Is_Red_Flag__c);
        System.assertEquals(1, [SELECT count() FROM Case_Symptom__c WHERE Case__c = :result.caseId]);
        System.assertEquals(1, [SELECT count() FROM Probable_Condition__c WHERE Case__c = :result.caseId]);
        System.assertEquals(1, [SELECT count() FROM Patient_Medication__c WHERE Patient__r.Patient_External_Id__c = 'PAT_TEST_ROUTINE']);
        System.assertEquals(1, [SELECT count() FROM Prior_Observation__c WHERE Patient__r.Patient_External_Id__c = 'PAT_TEST_ROUTINE']);
    }

    @IsTest
    static void submitIntakeRoutesRedFlagsToEmergencyMedicine() {
        TriageIntakeController.IntakeRequest request = new TriageIntakeController.IntakeRequest();
        request.patientExternalId = 'PAT_TEST_REDFLAG';
        request.durationDays = 1;
        request.severity = 'Severe';
        request.symptomExternalIds = new List<String>{ SYM_CHEST };

        Test.startTest();
        TriageIntakeController.IntakeResult result = TriageIntakeController.submitIntake(request);
        Test.stopTest();

        System.assertEquals('Critical', result.triageLevel, 'Expected red-flag intake to be critical.');
        System.assertEquals(true, result.isRedFlag, 'Expected a red-flag response.');
        System.assertEquals('Emergency Medicine', result.recommendedSpecialty, 'Expected red flags to route to Emergency Medicine.');
        System.assert(result.aiSummary.contains('RED-FLAG PATTERN'), 'Expected fallback summary to lead with red-flag escalation.');
    }

    @IsTest
    static void submitIntakeRequiresAtLeastOneSymptom() {
        TriageIntakeController.IntakeRequest request = new TriageIntakeController.IntakeRequest();
        request.symptomExternalIds = new List<String>();

        try {
            TriageIntakeController.submitIntake(request);
            System.assert(false, 'Expected an AuraHandledException for an empty symptom list.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Please select at least one symptom'));
        }
    }

    @IsTest
    static void submitIntakeRejectsBlankAndUnknownSymptoms() {
        TriageIntakeController.IntakeRequest request = new TriageIntakeController.IntakeRequest();
        request.symptomExternalIds = new List<String>{ ' ', SYM_FEVER, 'UNKNOWN_SYMPTOM' };

        try {
            TriageIntakeController.submitIntake(request);
            System.assert(false, 'Expected an AuraHandledException for unknown symptoms.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Please select a valid symptom'));
        }
    }

    @IsTest
    static void submitIntakeJsonRejectsBlankPayload() {
        try {
            TriageIntakeController.submitIntakeJson(' ');
            System.assert(false, 'Expected an AuraHandledException for a blank payload.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Please complete the intake form before submitting'));
        }

        try {
            TriageIntakeController.submitIntakeJson(null);
            System.assert(false, 'Expected an AuraHandledException for a null payload.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Please complete the intake form before submitting'));
        }
    }

    @IsTest
    static void submitIntakeJsonRejectsMalformedPayload() {
        try {
            TriageIntakeController.submitIntakeJson('not json');
            System.assert(false, 'Expected an AuraHandledException for malformed JSON.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('The intake request could not be read'));
        }
    }

    @IsTest
    static void submitIntakeJsonRejectsMissingSymptoms() {
        try {
            TriageIntakeController.submitIntakeJson('{}');
            System.assert(false, 'Expected an AuraHandledException for missing symptoms.');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('Please select at least one symptom'));
        }
    }
}
