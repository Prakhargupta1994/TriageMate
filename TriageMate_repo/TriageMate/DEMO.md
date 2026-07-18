# TriageMate — Demo cases

Three contrasting patients run through the same engine. Same rules, three explainable outcomes —
this is the "rules decide, AI explains" story in action.

| # | What the patient enters | Expected triage | Routed to | Red flag |
|---|---|---|---|---|
| 1 | "runny nose, sneezing, sore throat", 2 days | **Routine** | General Medicine | No |
| 2 | "really thirsty, peeing a lot, blurry vision, losing weight" (+ penicillin allergy, a medication) | **Urgent** | Endocrinology | No |
| 3 | "crushing chest pain spreading to my arm, sweating, short of breath" | **Critical** | Emergency Medicine | **Yes** |

## What each case demonstrates
- **Case 1 — the calm baseline.** A common cold scores low and comes back Routine. No alarm.
- **Case 2 — the AI reads history.** Scores Urgent and routes to Endocrinology; the GPT-5.6 doctor
  summary surfaces the penicillin allergy so nothing unsafe gets prescribed.
- **Case 3 — the emergency.** A red-flag pattern overrides scoring, escalates to Critical → Emergency
  Medicine, and shows the red-flag banner. This is exactly where a language model should never make the
  call — so it doesn't. A deterministic rule does.

## Why "Critical?" — the auditable answer
The urgency decision is a transparent weighted score plus a red-flag override, never the language model.
Every result shows the ranked probable conditions **with their scores**, so the reasoning is inspectable.
GPT-5.6 is used only to (1) interpret the free-text symptoms, (2) write the patient explanation, and
(3) write the clinician summary.

## Verify the engine directly (no UI needed)
The rule engine resolves the classic emergency presentation — chest pain radiating to the arm, sweating,
shortness of breath — to **Critical → Emergency Medicine → red flag: true**, deterministically, every run.

> Decision support, not a diagnosis. Red flags always escalate; a licensed clinician must confirm.
> The clinical knowledge base here is demo-grade.
