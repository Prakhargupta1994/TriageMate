public with sharing class OpenAITriageService {

    // Uses a Named Credential called 'OpenAI' (setup steps in the message).
    // Endpoint resolves to https://api.openai.com and the Bearer key is injected
    // by the External Credential, so we never hardcode the API key here.
    private static final String MODEL = 'gpt-5.6'; // confirm the current id at platform.openai.com/docs/models

    private static final String SYSTEM_PROMPT =
        'You are assisting a licensed clinician — NOT the patient. Read the patient presentation and ' +
        'write a brief, plain-language summary the clinician can skim in ten seconds. Use short sentences ' +
        'or 3-5 bullets. State the probable issues to consider for review; do NOT give a definitive ' +
        'diagnosis. If a red flag is present, lead with the escalation. Mention any current medication or ' +
        'allergy that affects what can be safely prescribed. Do not invent details not in the input.';

    // Callout ONLY — no DML in this method, so it is safe to call from an
    // @AuraEnabled action without "uncommitted work pending" errors.
    @AuraEnabled
    public static String generateAiSummary(String clinicalContext) {
        if (String.isBlank(clinicalContext)) return null;
        try {
            Map<String, Object> sysMsg = new Map<String, Object>{ 'role' => 'system', 'content' => SYSTEM_PROMPT };
            Map<String, Object> usrMsg = new Map<String, Object>{ 'role' => 'user',   'content' => clinicalContext };
            Map<String, Object> body = new Map<String, Object>{
                'model'       => MODEL,
                'messages'    => new List<Object>{ sysMsg, usrMsg },
                'temperature' => 0.3,
                'max_tokens'  => 500
            };

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:OpenAI/v1/chat/completions');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(JSON.serialize(body));

            HttpResponse res = new Http().send(req);
            System.debug('OPENAI status ' + res.getStatusCode());
            if (res.getStatusCode() != 200) {
                System.debug('OPENAI error body: ' + res.getBody());
                return null; // caller falls back to the deterministic summary
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> choices = (List<Object>) parsed.get('choices');
            if (choices == null || choices.isEmpty()) return null;
            Map<String, Object> first = (Map<String, Object>) choices[0];
            Map<String, Object> msg = (Map<String, Object>) first.get('message');
            String content = (String) msg.get('content');
            return String.isBlank(content) ? null : content.trim();

        } catch (Exception e) {
            System.debug('OPENAI callout failed: ' + e.getMessage());
            return null; // never let a flaky callout kill the demo
        }
    }
}
