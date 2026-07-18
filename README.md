# TriageMate

**Symptom triage that's safe by design — rules decide urgency, GPT-5.6 explains it.**
OpenAI Build Week · Track: *Apps for Your Life* · Built with **Codex + GPT-5.6**.

> **Decision support, not a diagnosis.** Every output is for clinician review; a licensed clinician must
> confirm. Red-flag patterns escalate to Emergency immediately. The clinical data here is demo-grade.

---

## The problem
People can't tell how urgent their symptoms are, so they either panic-search and spiral or wait too long.
Clinicians, meanwhile, rebuild each patient's story from scratch at the start of every visit.

## What it does
Describe your symptoms in plain language → get an urgency level, a specialty to see, and a clear summary
to bring to your doctor.

1. **Intake** — symptoms (free text or guided), duration, severity, medications, history.
2. **Triage + case** — a deterministic rules engine scores probable conditions, assigns
   Routine / Urgent / Critical, routes to a specialty, and applies an emergency **red-flag override**.
3. **Explanation** — GPT-5.6 writes a short, plain-language explanation for the patient.
4. **Doctor-ready output** — GPT-5.6 writes a concise clinician handoff (probable issues + urgency +
   medication/allergy flags).

## The core idea: **rules decide, AI explains**
The urgency decision is a transparent weighted score + red-flag override — never the language model. You
can always answer "why Critical?" by pointing at the scores. GPT-5.6 is used only where it's uniquely
strong: understanding free-text symptoms and writing the two summaries. Auditable intelligence; AI on
explanation duty, not diagnosis duty.

## How GPT-5.6 is used
- **Free-text → structured symptoms:** interpreting what the patient typed into known symptoms.
- **Patient explanation:** plain-language, calm, non-diagnostic; leads with escalation on a red flag.
- **Clinician summary:** a ten-second skim — ranked issues to consider, urgency, and any medication or
  allergy that affects safe prescribing.
The summary calls fall back to a deterministic template if the API is unavailable, so a demo never dies.

## How it was built with Codex
Codex (GPT-5.6) was used to build and extend the app — the Apex rules engine and orchestration, the
Lightning Web Component intake/results UI, and the GPT-5.6 integration.

## Architecture
- **Rules engine + orchestration:** Salesforce Apex (`TriageIntakeController`) — scores conditions from a
  weighted symptom→condition map, applies the red-flag override, creates the case + related records.
- **UI:** Lightning Web Component (`triageIntake`) — intake form and color-coded results (priority badge,
  red-flag banner, ranked probable conditions with scores, routed specialty, patient + doctor summaries).
- **AI:** GPT-5.6 for the two summaries.
- **Knowledge base:** 83 symptoms · 61 conditions · 280 weighted mappings · 16 specialties · 12 red-flag
  conditions.

## Explore it
Because this runs inside a Salesforce org, the fastest way to evaluate it is the **3-minute demo video**
(link in the submission), which shows the full flow on three contrasting patients.

**To run the triage engine directly** (no UI needed), the rule engine is exercised with a single call
that returns urgency, specialty, and red-flag status for a classic emergency presentation — chest pain
radiating to the arm with sweating and shortness of breath resolves to **Critical → Emergency Medicine →
red flag: true**. Reviewers can request scoped org access for a live walkthrough.

## Repo structure
- `/force-app` — Apex classes and the `triageIntake` LWC.
- `/data` — the clinical knowledge base (symptoms, conditions, weighted mappings, specialties).
- `DEMO.md` — the three demo cases and expected outcomes.

## Safety
Decision support only; not a diagnosis. Red flags escalate to Emergency. Mental-health crisis patterns
route to a human and never auto-close. Urgency is deterministic so it can be inspected and trusted. A
licensed clinician must validate the mapping before any real-world use.
