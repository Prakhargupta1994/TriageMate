import { LightningElement, wire, track } from 'lwc';
import getSymptoms from '@salesforce/apex/TriageIntakeController.getSymptoms';
// IMPORTANT: JSON entry point — sends the request as a String (inner-class params don't transport).
import submitIntakeJson from '@salesforce/apex/TriageIntakeController.submitIntakeJson';
// second call — GPT-5.6 writes the summary (kept separate so DML and the callout are in different transactions)
import generateAiSummary from '@salesforce/apex/OpenAITriageService.generateAiSummary';

const SEVERITY_OPTIONS = [
    { label: 'Mild', value: 'Mild' },
    { label: 'Moderate', value: 'Moderate' },
    { label: 'Severe', value: 'Severe' }
];

export default class TriageIntake extends LightningElement {
    severityOptions = SEVERITY_OPTIONS;

    // ===== set DEBUG = false to silence logs before the demo =====
    DEBUG = true;
    log(area, data) { if (this.DEBUG) { /* eslint-disable-next-line no-console */ console.log('[TriageIntake v3] ' + area, data !== undefined ? data : ''); } }
    logErr(area, data) { /* eslint-disable-next-line no-console */ console.error('[TriageIntake v3] ' + area, data !== undefined ? data : ''); }

    firstName = '';
    lastName = '';
    durationDays = 1;
    severity = 'Moderate';

    // symptom groups are the SINGLE SOURCE OF TRUTH: [{ system, items:[{id,label,checked}] }]
    @track groups = [];
    @track meds = [];
    @track observations = [];

    @track result;
    loading = false;
    errorMsg;
    hintMsg;

    connectedCallback() {
        this.log('INIT — build v3 (JSON transport) active');
    }

    @wire(getSymptoms)
    wiredSymptoms({ data, error }) {
        if (data) {
            this.log('WIRE getSymptoms — rows returned:', data.length);
            const bySystem = {};
            data.forEach((s) => {
                if (!bySystem[s.bodySystem]) bySystem[s.bodySystem] = [];
                bySystem[s.bodySystem].push({ id: s.externalId, label: s.label, checked: false });
            });
            this.groups = Object.keys(bySystem).map((system) => ({ system, items: bySystem[system] }));
            if (data.length === 0) this.logErr('WIRE getSymptoms — 0 symptoms. Check data load / FLS on Symptom__c.');
        } else if (error) {
            this.logErr('WIRE getSymptoms — ERROR:', JSON.stringify(error));
            this.errorMsg = 'Could not load symptoms. Confirm the reference data is loaded.';
        }
    }

    handleFirst(e) { this.firstName = e.target.value; }
    handleLast(e) { this.lastName = e.target.value; }
    handleDuration(e) {
        const value = parseInt(e.target.value, 10);
        this.durationDays = Number.isNaN(value) ? 1 : Math.max(value, 1);
    }
    handleSeverity(e) { this.severity = e.detail.value; }

    handleSymptomToggle(e) {
        const id = e.target.dataset.id;
        const checked = e.target.checked;
        this.hintMsg = undefined;
        this.errorMsg = undefined;
        this.groups = this.groups.map((g) => ({
            system: g.system,
            items: g.items.map((it) => (it.id === id ? { ...it, checked: checked } : it))
        }));
        this.log('TOGGLE:', { id: id, checked: checked, selectedNow: this.selectedIds });
    }

    // selection derived from the rendered model — a box that shows checked IS counted
    get selectedIds() {
        const ids = [];
        this.groups.forEach((g) => g.items.forEach((it) => { if (it.checked) ids.push(it.id); }));
        return ids;
    }
    get selectedCount() { return this.selectedIds.length; }
    get showHint() { return this.selectedCount === 0; }

    addMed() { this.meds = [...this.meds, { key: Date.now() + '-' + this.meds.length, drugName: '', dosage: '', frequency: '' }]; }
    removeMed(e) { const key = e.target.dataset.key; this.meds = this.meds.filter((m) => m.key !== key); }
    handleMedChange(e) {
        const key = e.target.dataset.key; const field = e.target.dataset.field;
        this.meds = this.meds.map((m) => (m.key === key ? { ...m, [field]: e.target.value } : m));
    }

    addObs() { this.observations = [...this.observations, { key: Date.now() + '-' + this.observations.length, text: '' }]; }
    removeObs(e) { const key = e.target.dataset.key; this.observations = this.observations.filter((o) => o.key !== key); }
    handleObsChange(e) {
        const key = e.target.dataset.key;
        this.observations = this.observations.map((o) => (o.key === key ? { ...o, text: e.target.value } : o));
    }

    get submitDisabled() { return this.loading; }

    async handleSubmit() {
        this.errorMsg = undefined;
        this.hintMsg = undefined;
        const ids = this.selectedIds;
        this.log('SUBMIT — selected symptom ids:', ids);
        if (ids.length === 0) {
            this.hintMsg = 'Select at least one symptom to continue.';
            this.log('SUBMIT blocked — nothing selected');
            return;
        }
        this.result = undefined;
        this.loading = true;
        const clean = (value) => (value || '').trim();
        const req = {
            patientFirstName: clean(this.firstName),
            patientLastName: clean(this.lastName),
            durationDays: this.durationDays,
            severity: this.severity,
            symptomExternalIds: ids,
            medications: this.meds
                .map((m) => ({ drugName: clean(m.drugName), dosage: clean(m.dosage), frequency: clean(m.frequency) }))
                .filter((m) => m.drugName),
            priorObservations: this.observations.map((o) => clean(o.text)).filter((t) => t)
        };
        const payload = JSON.stringify(req);
        this.log('SUBMIT — payload prepared');
        try {
            // send as a STRING — this is the fix for the empty-symptoms bug
            this.result = await submitIntakeJson({ payload: payload });
            this.log('SUBMIT — result received');
            if (this.result && this.result.aiContext) {
                try {
                    const gpt = await generateAiSummary({ clinicalContext: this.result.aiContext });
                    if (gpt) {
                        this.result = { ...this.result, aiSummary: gpt, aiUsed: true };
                        this.log('SUBMIT — GPT-5.6 summary applied');
                    }
                } catch (ge) {
                    this.logErr('GPT-5.6 summary failed, keeping deterministic fallback', ge);
                }
            }
        } catch (e) {
            this.errorMsg = (e && e.body && e.body.message) ? e.body.message : 'Something went wrong submitting the intake.';
            this.logErr('SUBMIT — ERROR:', this.errorMsg);
        } finally {
            this.loading = false;
            this.log('SUBMIT — finished. hasResult:', this.hasResult);
        }
    }

    handleReset() {
        this.result = undefined;
        this.errorMsg = undefined;
        this.hintMsg = undefined;
        this.meds = [];
        this.observations = [];
        this.firstName = '';
        this.lastName = '';
        this.durationDays = 1;
        this.severity = 'Moderate';
        this.groups = this.groups.map((g) => ({ system: g.system, items: g.items.map((it) => ({ ...it, checked: false })) }));
    }

    get hasResult() { return this.result != null; }
    get recommendedSpecialtyLabel() {
        return this.result && this.result.recommendedSpecialty ? this.result.recommendedSpecialty : 'Clinician review';
    }
    get priorityClass() {
        const base = 'priority-badge ';
        if (!this.result) return base;
        if (this.result.triageLevel === 'Critical') return base + 'is-critical';
        if (this.result.triageLevel === 'Urgent') return base + 'is-urgent';
        return base + 'is-routine';
    }
    get rankedForDisplay() {
        if (!this.result || !this.result.probableConditions) return [];
        return this.result.probableConditions.slice(0, 3).map((c) => ({ ...c, badge: c.isRedFlag ? 'Red flag' : c.priority }));
    }
    get aiSourceLabel() { return this.result && this.result.aiUsed ? 'GPT-5.6 summary' : 'Generated summary'; }
}
