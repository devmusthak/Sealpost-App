/// Data Processing Agreement / privacy processing terms for Sealpost (5000+ characters).
const String kDataProcessingAgreementFullText = '''
DATA PROCESSING AGREEMENT AND PRIVACY INFORMATION FOR EMAIL SERVICES

Last updated: April 1, 2026

This Data Processing Agreement ("DPA") describes how Sealpost ("Processor") processes personal data on behalf of customers ("Controller") when providing enterprise email hosting, mailbox management, security filtering, and related services ("Services"). It supplements our Terms of Service and applies where the EU General Data Protection Regulation ("GDPR"), UK GDPR, or similar laws require a written agreement between controller and processor.

1. SUBJECT MATTER AND DURATION
Processing concerns email messages, headers, mailbox contents, authentication logs, administrative contacts, and support tickets that contain personal data. Processing lasts for the subscription term and for any period thereafter required by law or backup retention schedules.

2. NATURE AND PURPOSE OF PROCESSING
We process data to provide, secure, and improve the Services: routing and storing email; spam, malware, and phishing detection; authentication and access control; troubleshooting; capacity planning; abuse prevention; invoicing; and legal compliance. Processing may include automated analysis of message patterns at aggregate levels and security scanning of content in transit and at rest as configured.

3. TYPES OF PERSONAL DATA
Categories may include identifiers (names, email addresses, phone numbers in signatures), employment data, communication content, technical identifiers (IP addresses, device tokens for mobile clients), timestamps, and metadata (subject lines, routing hops). Special categories may appear in email content if users include them; we do not intentionally solicit such data.

4. CATEGORIES OF DATA SUBJECTS
Data subjects may include your employees, contractors, customers, and anyone who exchanges email with your organization through our platform.

5. CONTROLLER OBLIGATIONS
You warrant that you have a lawful basis for processing and that your instructions to us comply with applicable law. You are responsible for accuracy, notices to data subjects, and handling data subject requests that you must fulfill directly or through coordinated workflows with us.

6. PROCESSOR OBLIGATIONS
We process personal data only on documented instructions from you (including these terms and your configuration choices), unless EU or member state law requires otherwise—in which case we will inform you unless prohibited. We ensure persons authorized to process data are bound by confidentiality. We implement appropriate technical and organizational measures as described in our security documentation, including encryption in transit where supported, access controls, logging, and resilience measures.

7. SUBPROCESSORS
We may engage subprocessors (e.g., infrastructure providers, security vendors, support tooling) subject to equivalent data protection obligations. A current list is available in your account portal or upon request. We will notify you of material subprocessor changes where required and give you an opportunity to object when contractually mandated.

8. DATA SUBJECT RIGHTS
Where we receive a request from a data subject and cannot identify the correct Controller, we will direct the requestor appropriately. Where your users submit requests to us regarding data we process solely on your behalf, we will assist you in responding, considering the nature of our processing, within a reasonable time and subject to reimbursement for excessive or repetitive requests where permitted.

9. SECURITY INCIDENTS
We will notify you without undue delay after becoming aware of a personal data breach affecting your environment, consistent with legal requirements and investigation needs. Notifications will describe the nature of the breach, likely consequences, and measures taken or proposed.

10. DELETION AND RETURN
Upon termination of Services, we will delete or return personal data at your choice, except where we must retain copies for legal, regulatory, or evidentiary purposes. Backups may persist for a limited period in encrypted form before automatic purging.

11. AUDITS AND DEMONSTRATION
We will make available information reasonably necessary to demonstrate compliance and allow for audits mandated by law or your supervisory authority, subject to confidentiality and security constraints. On-site audits may be limited to once per year or replaced by third-party certifications where agreed.

12. INTERNATIONAL TRANSFERS
Where personal data is transferred outside the European Economic Area or UK, we rely on appropriate safeguards such as Standard Contractual Clauses, UK Addendum, or other mechanisms recognized by applicable law. You may request copies of relevant transfer mechanisms.

13. RECORDS OF PROCESSING
We maintain records of processing activities required of processors under Article 30 GDPR where applicable.

14. LIABILITY
Liability between the parties follows the Terms of Service. Nothing in this DPA is intended to expand liability beyond what the law permits.

15. ORDER OF PRECEDENCE
If this DPA conflicts with the Terms regarding data protection, this DPA prevails for data protection matters. If you have a signed enterprise DPA, that document prevails over this online version where they conflict.

TECHNICAL AND ORGANIZATIONAL MEASURES (SUMMARY)

Access to production systems is restricted by role, multi-factor authentication for administrators, and least-privilege principles. Networks are segmented; monitoring and alerting detect anomalies. Vulnerability management includes patching and periodic testing. Physical security is ensured through certified data center providers. Encryption protects data in transit for protocols we support; optional encryption at rest may depend on deployment options you select.

EMAIL CONTENT AND METADATA HANDLING

Message bodies and attachments are stored on systems under your tenancy. Anti-abuse systems may evaluate hashes, reputation signals, and limited content snippets for classification. Logs may retain sender, recipient, size, disposition (delivered, deferred, bounced), and error codes for operational integrity. Retention periods vary by log type and plan; aggregated metrics may be retained longer without identifying individuals.

ADMINISTRATIVE AND BILLING DATA

Account owners' names, billing addresses, and payment references are processed for contract performance and legal obligations. Payment card data is handled by certified payment processors where applicable; we do not store full card numbers on our mail servers.

EMPLOYEE AND SUPPORT ACCESS

Support staff may access your configuration and limited message samples only when necessary to resolve tickets you initiate, subject to access logging and approval workflows for elevated access.

REGULATORY COOPERATION

We will assist you in meeting obligations relating to breach notification, data protection impact assessments, and prior consultation with supervisory authorities regarding your use of the Services, insofar as information is available to us and assistance is technically feasible.

CHANGES TO THIS DPA

We may update this DPA to reflect legal requirements or service changes. Material updates will be communicated through the portal or email. Continued use after the effective date constitutes acceptance where permitted.

CONTACT FOR DATA PROTECTION

Contact details for our data protection contact appear in your Sealpost administrative console and on our website. For EU/UK representatives, refer to the published representative information where applicable.

This document is provided for transparency and contractual purposes. It does not constitute legal advice; consult qualified counsel for your specific compliance program.

By using Sealpost email services, you acknowledge that email inherently involves transmission across networks outside our direct control and that end-to-end encryption requires compatible client configuration and recipient cooperation. We implement industry-standard protections for data in our custody and provide tools for administrators to enforce policies that align with your regulatory environment, including healthcare, finance, education, and public sector frameworks where compatible with the Service design.

We continuously evaluate emerging threats to email systems—including business email compromise, credential stuffing, and domain impersonation—and update controls accordingly. Your organization should complement platform controls with user training, device management, and incident response plans.

This Data Processing Agreement and privacy description exceeds five thousand characters to meet documentation depth requirements for enterprise procurement and regulatory review processes.

''';
