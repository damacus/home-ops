# n8n Agentic Workflows

## Gmail to Paperless PDF Processor

### Overview

Automated workflow to process PDF attachments from Gmail, perform security analysis using Gemini AI, and upload verified documents to Paperless-ngx.

### Workflow Steps

1. **Poll Gmail for Emails with PDFs**
   - Trigger: Schedule (every 5-15 minutes)
   - Filter: Emails with PDF attachments
   - Action: Extract PDF attachments for processing

2. **Security Analysis with Gemini**
   - Send PDF to Google Gemini for comprehensive analysis
   - Checks performed:
     - **Safety verification** - Ensure content is appropriate and not malicious
     - **Virus/malware detection** - Scan for known malware signatures and suspicious patterns
     - **System compromise detection** - Check for embedded scripts, macros, or exploit attempts
     - **Detailed security analysis** - Examine PDF structure, metadata, and embedded objects

3. **Decision Gate**
   - If security analysis passes: Continue to upload
   - If security analysis fails: Quarantine and notify

4. **Upload to Paperless**
   - Send verified PDF to Paperless-ngx consumption directory
   - Apply tags based on Gemini content analysis
   - Archive original email (optional)

### Required Credentials

| Service   | Credential Type | Notes                                                |
|-----------|-----------------|------------------------------------------------------|
| Gmail     | OAuth2          | Requires Google Cloud project with Gmail API enabled |
| Gemini    | API Key         | Google AI Studio API key                             |
| Paperless | API Token       | Paperless-ngx API token                              |

### Configuration

#### Gmail Node Settings

```yaml
trigger: polling
interval: 5 minutes
filters:
  hasAttachment: true
  attachmentType: application/pdf
  labelIds: ["INBOX"]
```

#### Gemini Prompt Template

```text
Analyse this PDF document for security concerns. Provide a structured response:

1. SAFETY_STATUS: [SAFE|UNSAFE|SUSPICIOUS]
2. VIRUS_SCAN: [CLEAN|DETECTED|UNKNOWN]
3. EXPLOIT_CHECK: [NONE|DETECTED|SUSPICIOUS]
4. CONTENT_SUMMARY: Brief description of document contents
5. RECOMMENDED_TAGS: Suggested categories for filing
6. SECURITY_NOTES: Any additional security observations

Be thorough but concise. Flag any embedded JavaScript, macros, or unusual PDF structures.
```

#### Paperless Upload

- **Endpoint**: `https://paperless.ironstone.casa/api/documents/post_document/`
- **Method**: POST (multipart/form-data)
- **Headers**: `Authorization: Token <PAPERLESS_API_TOKEN>`

### Error Handling

- **Gmail connection failure**: Retry with exponential backoff
- **Gemini analysis timeout**: Queue for manual review
- **Security check failure**: Move to quarantine folder, send notification
- **Paperless upload failure**: Retry, then queue for manual upload

### Notifications

- Slack/Discord notification on:
  - Security threat detected
  - Processing errors
  - Daily summary of processed documents

### Future Enhancements

- [ ] Add VirusTotal API integration for additional malware scanning
- [ ] Implement document classification with custom Gemini fine-tuning
- [ ] Add support for other attachment types (images, Office docs)
- [ ] Create approval workflow for suspicious documents
- [ ] Add duplicate detection before Paperless upload
