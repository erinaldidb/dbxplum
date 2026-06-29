#!/usr/bin/env node
/**
 * Medplum Project Initialization Script
 * 
 * Creates a reproducible initial load for the Medplum FHIR platform on Databricks.
 * 
 * Usage:
 *   node scripts/init-project.js [--base-url URL] [--reset]
 * 
 * Default base URL: https://your-app-url.aws.databricksapps.com
 * 
 * What this script creates:
 *   1. A new project: "Databricks Health Platform"
 *   2. An admin Practitioner
 *   3. An Organization (main healthcare org)
 *   4. Sample Patients (5 realistic test patients)
 *   5. Sample Practitioners (3 — doctor, nurse, admin)
 *   6. Sample Encounters & Observations
 *   7. A ClientApplication for API access
 */

import { execSync } from 'node:child_process';

const BASE_URL = process.argv.find(a => a.startsWith('--base-url='))?.split('=')[1]
  || process.env.MEDPLUM_BASE_URL
  || 'https://your-app-url.aws.databricksapps.com';

const PROFILE = process.argv.find(a => a.startsWith('--profile='))?.split('=')[1]
  || process.env.DATABRICKS_PROFILE
  || 'your-profile';

const ADMIN_EMAIL = 'admin@example.com';
const ADMIN_PASSWORD = 'medplum_admin';

// --- Helpers ---

function getDatabricksToken() {
  try {
    const output = execSync(`databricks auth token --profile ${PROFILE}`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] });
    return JSON.parse(output).access_token;
  } catch {
    console.error('ERROR: Could not get Databricks token. Make sure the Databricks CLI is configured.');
    console.error(`  Profile: ${PROFILE}`);
    console.error('  Run: databricks auth login --profile ' + PROFILE);
    process.exit(1);
  }
}

let gatewayToken = null;

async function request(path, options = {}) {
  if (!gatewayToken) gatewayToken = getDatabricksToken();
  const url = `${BASE_URL}${path}`;
  const res = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${gatewayToken}`,
      ...options.headers,
    },
  });
  const text = await res.text();
  let body;
  try { body = JSON.parse(text); } catch { body = text; }
  if (!res.ok) {
    throw new Error(`${res.status} ${res.statusText}: ${path}\n${JSON.stringify(body, null, 2)}`);
  }
  return body;
}

async function authenticate() {
  console.log(`Authenticating as ${ADMIN_EMAIL}...`);
  
  // Step 1: Login
  const loginRes = await request('/auth/login', {
    method: 'POST',
    body: JSON.stringify({
      email: ADMIN_EMAIL,
      password: ADMIN_PASSWORD,
      scope: 'openid',
      codeChallengeMethod: 'plain',
      codeChallenge: 'init-script-challenge',
    }),
  });

  // Step 2: Exchange code for token
  const tokenRes = await request('/oauth2/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: loginRes.code,
      code_verifier: 'init-script-challenge',
    }).toString(),
  });

  console.log('✓ Authenticated successfully');
  return tokenRes.access_token;
}

function authHeaders(medplumToken) {
  // Gateway auth via Databricks token in Authorization header
  // Medplum auth via cookie (since gateway strips non-Databricks Authorization headers)
  return {
    Authorization: `Bearer ${gatewayToken}`,
    Cookie: `__medplum_token=${medplumToken}`,
  };
}

async function createResource(token, resource) {
  return request(`/fhir/R4/${resource.resourceType}`, {
    method: 'POST',
    headers: authHeaders(token),
    body: JSON.stringify(resource),
  });
}

async function searchResource(token, resourceType, params) {
  const qs = new URLSearchParams(params).toString();
  return request(`/fhir/R4/${resourceType}?${qs}`, {
    headers: authHeaders(token),
  });
}

// --- Data Definitions ---

const ORGANIZATION = {
  resourceType: 'Organization',
  name: 'Databricks Health Platform',
  identifier: [{ system: 'https://databricks.com/org', value: 'databricks-health-001' }],
  type: [{ coding: [{ system: 'http://terminology.hl7.org/CodeSystem/organization-type', code: 'prov', display: 'Healthcare Provider' }] }],
  telecom: [
    { system: 'phone', value: '+1-555-0100', use: 'work' },
    { system: 'email', value: 'admin@databricks-health.example.com', use: 'work' },
  ],
  address: [{
    use: 'work',
    line: ['160 Spear Street', 'Suite 1300'],
    city: 'San Francisco',
    state: 'CA',
    postalCode: '94105',
    country: 'US',
  }],
};

const PRACTITIONERS = [
  {
    resourceType: 'Practitioner',
    identifier: [{ system: 'http://hl7.org/fhir/sid/us-npi', value: '1234567890' }],
    name: [{ family: 'Chen', given: ['Sarah', 'L'], prefix: ['Dr.'] }],
    gender: 'female',
    telecom: [
      { system: 'email', value: 'sarah.chen@databricks-health.example.com' },
      { system: 'phone', value: '+1-555-0101' },
    ],
    qualification: [{
      code: { coding: [{ system: 'http://terminology.hl7.org/CodeSystem/v2-0360', code: 'MD', display: 'Doctor of Medicine' }] },
    }],
  },
  {
    resourceType: 'Practitioner',
    identifier: [{ system: 'http://hl7.org/fhir/sid/us-npi', value: '2345678901' }],
    name: [{ family: 'Johnson', given: ['Michael', 'R'], prefix: ['RN'] }],
    gender: 'male',
    telecom: [{ system: 'email', value: 'michael.johnson@databricks-health.example.com' }],
    qualification: [{
      code: { coding: [{ system: 'http://terminology.hl7.org/CodeSystem/v2-0360', code: 'RN', display: 'Registered Nurse' }] },
    }],
  },
  {
    resourceType: 'Practitioner',
    identifier: [{ system: 'http://hl7.org/fhir/sid/us-npi', value: '3456789012' }],
    name: [{ family: 'Patel', given: ['Anita'], prefix: ['Dr.'] }],
    gender: 'female',
    telecom: [{ system: 'email', value: 'anita.patel@databricks-health.example.com' }],
    qualification: [{
      code: { coding: [{ system: 'http://terminology.hl7.org/CodeSystem/v2-0360', code: 'MD', display: 'Doctor of Medicine' }] },
    }],
  },
];

const PATIENTS = [
  {
    resourceType: 'Patient',
    identifier: [{ system: 'https://databricks-health.example.com/mrn', value: 'MRN-001' }],
    name: [{ family: 'Garcia', given: ['Maria', 'Elena'], use: 'official' }],
    gender: 'female',
    birthDate: '1985-03-15',
    telecom: [
      { system: 'phone', value: '+1-555-0201', use: 'home' },
      { system: 'email', value: 'maria.garcia@example.com' },
    ],
    address: [{ use: 'home', line: ['123 Oak Street'], city: 'San Francisco', state: 'CA', postalCode: '94102', country: 'US' }],
    maritalStatus: { coding: [{ system: 'http://terminology.hl7.org/CodeSystem/v3-MaritalStatus', code: 'M', display: 'Married' }] },
    communication: [{ language: { coding: [{ system: 'urn:ietf:bcp:47', code: 'en', display: 'English' }] }, preferred: true }],
  },
  {
    resourceType: 'Patient',
    identifier: [{ system: 'https://databricks-health.example.com/mrn', value: 'MRN-002' }],
    name: [{ family: 'Williams', given: ['James', 'Robert'], use: 'official' }],
    gender: 'male',
    birthDate: '1972-08-22',
    telecom: [{ system: 'phone', value: '+1-555-0202', use: 'mobile' }],
    address: [{ use: 'home', line: ['456 Pine Avenue'], city: 'Oakland', state: 'CA', postalCode: '94610', country: 'US' }],
  },
  {
    resourceType: 'Patient',
    identifier: [{ system: 'https://databricks-health.example.com/mrn', value: 'MRN-003' }],
    name: [{ family: 'Kim', given: ['Soo-Yeon'], use: 'official' }],
    gender: 'female',
    birthDate: '1990-11-08',
    telecom: [{ system: 'email', value: 'sooyeon.kim@example.com' }],
    address: [{ use: 'home', line: ['789 Market St', 'Apt 4B'], city: 'San Francisco', state: 'CA', postalCode: '94103', country: 'US' }],
  },
  {
    resourceType: 'Patient',
    identifier: [{ system: 'https://databricks-health.example.com/mrn', value: 'MRN-004' }],
    name: [{ family: 'Thompson', given: ['Robert', 'Allan'], use: 'official' }],
    gender: 'male',
    birthDate: '1958-01-30',
    telecom: [{system: 'phone', value: '+1-555-0204', use: 'home' }],
    address: [{ use: 'home', line: ['321 Elm Drive'], city: 'Berkeley', state: 'CA', postalCode: '94704', country: 'US' }],
    maritalStatus: { coding: [{ system: 'http://terminology.hl7.org/CodeSystem/v3-MaritalStatus', code: 'W', display: 'Widowed' }] },
  },
  {
    resourceType: 'Patient',
    identifier: [{ system: 'https://databricks-health.example.com/mrn', value: 'MRN-005' }],
    name: [{ family: 'Okafor', given: ['Chidinma'], use: 'official' }],
    gender: 'female',
    birthDate: '1995-06-12',
    telecom: [
      { system: 'phone', value: '+1-555-0205', use: 'mobile' },
      { system: 'email', value: 'chidinma.okafor@example.com' },
    ],
    address: [{ use: 'home', line: ['555 Valencia St'], city: 'San Francisco', state: 'CA', postalCode: '94110', country: 'US' }],
  },
];

function createEncounter(patientRef, practitionerRef, orgRef, dateStr, reasonText) {
  return {
    resourceType: 'Encounter',
    status: 'finished',
    class: { system: 'http://terminology.hl7.org/CodeSystem/v3-ActCode', code: 'AMB', display: 'ambulatory' },
    subject: patientRef,
    participant: [{ individual: practitionerRef }],
    serviceProvider: orgRef,
    period: { start: `${dateStr}T09:00:00Z`, end: `${dateStr}T09:30:00Z` },
    reasonCode: [{ text: reasonText }],
  };
}

function createObservation(patientRef, encounterRef, code, value, unit, dateStr) {
  return {
    resourceType: 'Observation',
    status: 'final',
    category: [{ coding: [{ system: 'http://terminology.hl7.org/CodeSystem/observation-category', code: 'vital-signs', display: 'Vital Signs' }] }],
    code: { coding: [code] },
    subject: patientRef,
    encounter: encounterRef,
    effectiveDateTime: `${dateStr}T09:15:00Z`,
    valueQuantity: { value, unit, system: 'http://unitsofmeasure.org', code: unit },
  };
}

const VITAL_SIGNS = {
  systolicBP: { system: 'http://loinc.org', code: '8480-6', display: 'Systolic blood pressure' },
  diastolicBP: { system: 'http://loinc.org', code: '8462-4', display: 'Diastolic blood pressure' },
  heartRate: { system: 'http://loinc.org', code: '8867-4', display: 'Heart rate' },
  bodyTemp: { system: 'http://loinc.org', code: '8310-5', display: 'Body temperature' },
  bodyWeight: { system: 'http://loinc.org', code: '29463-7', display: 'Body weight' },
  bodyHeight: { system: 'http://loinc.org', code: '8302-2', display: 'Body height' },
  bmi: { system: 'http://loinc.org', code: '39156-5', display: 'BMI' },
};

// --- Main ---

async function main() {
  console.log('=== Medplum Project Initialization ===');
  console.log(`Base URL: ${BASE_URL}`);
  console.log('');

  // Authenticate
  const token = await authenticate();

  // Create Organization
  console.log('\n--- Creating Organization ---');
  const org = await createResource(token, ORGANIZATION);
  console.log(`✓ Organization: ${org.name} (${org.id})`);
  const orgRef = { reference: `Organization/${org.id}` };

  // Create Practitioners
  console.log('\n--- Creating Practitioners ---');
  const practitioners = [];
  for (const p of PRACTITIONERS) {
    const created = await createResource(token, p);
    practitioners.push(created);
    console.log(`✓ Practitioner: ${created.name[0].prefix?.[0] || ''} ${created.name[0].given.join(' ')} ${created.name[0].family} (${created.id})`);
  }

  // Create Patients
  console.log('\n--- Creating Patients ---');
  const patients = [];
  for (const p of PATIENTS) {
    p.managingOrganization = orgRef;
    p.generalPractitioner = [{ reference: `Practitioner/${practitioners[0].id}` }];
    const created = await createResource(token, p);
    patients.push(created);
    console.log(`✓ Patient: ${created.name[0].given.join(' ')} ${created.name[0].family} (MRN: ${created.identifier[0].value})`);
  }

  // Create Encounters & Observations
  console.log('\n--- Creating Encounters & Observations ---');
  const encounterData = [
    { patientIdx: 0, practIdx: 0, date: '2025-01-15', reason: 'Annual physical examination' },
    { patientIdx: 1, practIdx: 0, date: '2025-01-16', reason: 'Follow-up: Hypertension management' },
    { patientIdx: 2, practIdx: 2, date: '2025-01-17', reason: 'New patient visit' },
    { patientIdx: 3, practIdx: 0, date: '2025-01-18', reason: 'Chronic disease management' },
    { patientIdx: 4, practIdx: 2, date: '2025-01-19', reason: 'Wellness check' },
    { patientIdx: 0, practIdx: 1, date: '2025-02-10', reason: 'Vaccination - influenza' },
    { patientIdx: 1, practIdx: 0, date: '2025-02-15', reason: 'Lab results review' },
  ];

  // Vitals data for each encounter (realistic values)
  const vitalsData = [
    { systolic: 118, diastolic: 76, hr: 72, temp: 36.6, weight: 62, height: 165 },
    { systolic: 145, diastolic: 92, hr: 80, temp: 36.7, weight: 88, height: 178 },
    { systolic: 112, diastolic: 70, hr: 68, temp: 36.5, weight: 55, height: 163 },
    { systolic: 152, diastolic: 95, hr: 76, temp: 36.8, weight: 95, height: 175 },
    { systolic: 110, diastolic: 68, hr: 65, temp: 36.6, weight: 58, height: 170 },
    { systolic: 120, diastolic: 78, hr: 74, temp: 36.7, weight: 62, height: 165 },
    { systolic: 138, diastolic: 88, hr: 78, temp: 36.6, weight: 87, height: 178 },
  ];

  for (let i = 0; i < encounterData.length; i++) {
    const ed = encounterData[i];
    const patientRef = { reference: `Patient/${patients[ed.patientIdx].id}` };
    const practRef = { reference: `Practitioner/${practitioners[ed.practIdx].id}` };

    const encounter = await createResource(token, createEncounter(patientRef, practRef, orgRef, ed.date, ed.reason));
    const encRef = { reference: `Encounter/${encounter.id}` };
    console.log(`✓ Encounter: ${patients[ed.patientIdx].name[0].family} - ${ed.reason} (${ed.date})`);

    const v = vitalsData[i];
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.systolicBP, v.systolic, 'mmHg', ed.date));
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.diastolicBP, v.diastolic, 'mmHg', ed.date));
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.heartRate, v.hr, '/min', ed.date));
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.bodyTemp, v.temp, 'Cel', ed.date));
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.bodyWeight, v.weight, 'kg', ed.date));
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.bodyHeight, v.height, 'cm', ed.date));
    const bmi = Math.round((v.weight / (v.height / 100) ** 2) * 10) / 10;
    await createResource(token, createObservation(patientRef, encRef, VITAL_SIGNS.bmi, bmi, 'kg/m2', ed.date));
  }

  // Create a ClientApplication for programmatic API access
  console.log('\n--- Creating ClientApplication ---');
  const clientApp = await createResource(token, {
    resourceType: 'ClientApplication',
    name: 'Databricks Integration Client',
    description: 'Client application for Databricks notebooks and pipelines to access FHIR data',
    secret: 'databricks-fhir-client-secret-2025',
  });
  console.log(`✓ ClientApplication: ${clientApp.name} (ID: ${clientApp.id})`);

  // Summary
  console.log('\n\n========================================');
  console.log('  INITIALIZATION COMPLETE');
  console.log('========================================');
  console.log(`  Organization: ${org.name}`);
  console.log(`  Practitioners: ${practitioners.length}`);
  console.log(`  Patients: ${patients.length}`);
  console.log(`  Encounters: ${encounterData.length}`);
  console.log(`  Observations: ${encounterData.length * 7} (7 vitals per encounter)`);
  console.log(`  ClientApplication: ${clientApp.name}`);
  console.log('');
  console.log('  Admin Login:');
  console.log(`    Email: ${ADMIN_EMAIL}`);
  console.log(`    Password: ${ADMIN_PASSWORD}`);
  console.log('');
  console.log('  API Client Credentials:');
  console.log(`    Client ID: ${clientApp.id}`);
  console.log(`    Client Secret: databricks-fhir-client-secret-2025`);
  console.log('');
  console.log(`  FHIR Base URL: ${BASE_URL}/fhir/R4/`);
  console.log('========================================');
}

main().catch((err) => {
  console.error('\n❌ Initialization failed:', err.message);
  process.exit(1);
});
