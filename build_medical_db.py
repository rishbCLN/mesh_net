#!/usr/bin/env python3
"""
build_medical_db.py  –  Generate assets/medical/medical.db
==========================================================
Deterministic, offline medical-guidance database for MeshAlert's
"Local Doctor" feature. Synthesised from:
  • 2024 AHA / Red Cross First Aid Guidelines
  • WHO-ICRC Basic Emergency Care (BEC)
  • Mayo Clinic first-aid protocols
  • Wikipedia / MedlinePlus first-aid references

Run:  python build_medical_db.py
Output: assets/medical/medical.db  (~250 KB)
"""

import json
import os
import sqlite3
import pathlib

DB_DIR = pathlib.Path(__file__).resolve().parent / "assets" / "medical"
DB_PATH = DB_DIR / "medical.db"

# ── Schema ──────────────────────────────────────────────────────────────

SCHEMA = """
CREATE TABLE IF NOT EXISTS conditions (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    triage      TEXT    NOT NULL CHECK(triage IN ('RED','YELLOW','GREEN')),
    body_system TEXT,
    summary     TEXT
);

CREATE TABLE IF NOT EXISTS condition_symptoms (
    id           INTEGER PRIMARY KEY,
    condition_id INTEGER NOT NULL REFERENCES conditions(id),
    symptom      TEXT    NOT NULL,
    weight       REAL    NOT NULL DEFAULT 1.0
);

CREATE TABLE IF NOT EXISTS phrases (
    id           INTEGER PRIMARY KEY,
    condition_id INTEGER NOT NULL REFERENCES conditions(id),
    phrase       TEXT    NOT NULL,
    canonical    TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS decision_trees (
    id           INTEGER PRIMARY KEY,
    condition_id INTEGER NOT NULL UNIQUE REFERENCES conditions(id),
    tree_json    TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS protocols (
    id           INTEGER PRIMARY KEY,
    condition_id INTEGER NOT NULL REFERENCES conditions(id),
    step_order   INTEGER NOT NULL,
    title        TEXT    NOT NULL,
    detail       TEXT    NOT NULL,
    warning      TEXT
);

CREATE TABLE IF NOT EXISTS medications (
    id           INTEGER PRIMARY KEY,
    condition_id INTEGER NOT NULL REFERENCES conditions(id),
    name         TEXT    NOT NULL,
    dose         TEXT,
    route        TEXT,
    notes        TEXT
);

CREATE INDEX IF NOT EXISTS idx_phrases_phrase ON phrases(phrase);
CREATE INDEX IF NOT EXISTS idx_cs_cond ON condition_symptoms(condition_id);
CREATE INDEX IF NOT EXISTS idx_proto_cond ON protocols(condition_id);
CREATE INDEX IF NOT EXISTS idx_meds_cond ON medications(condition_id);
"""

# ── Condition data ──────────────────────────────────────────────────────
# (name, triage, body_system, summary)

CONDITIONS = [
    # RED – Life threatening
    ("Cardiac Arrest", "RED", "cardiovascular",
     "No pulse, no breathing. Begin CPR immediately. Use AED if available."),
    ("Heart Attack", "RED", "cardiovascular",
     "Chest pain/pressure radiating to arm/jaw, sweating, nausea. Chew aspirin 325 mg, call EMS."),
    ("Severe Bleeding", "RED", "trauma",
     "Life-threatening hemorrhage. Apply direct pressure, tourniquet if extremity bleed uncontrolled."),
    ("Choking – Adult", "RED", "airway",
     "Complete airway obstruction. Perform 5 back blows then 5 abdominal thrusts (Heimlich)."),
    ("Choking – Child", "RED", "airway",
     "Airway obstruction in child >1 yr. 5 back blows + 5 abdominal thrusts."),
    ("Choking – Infant", "RED", "airway",
     "Airway obstruction in infant <1 yr. 5 back thumps + 5 chest compressions."),
    ("Stroke", "RED", "neurological",
     "FAST: Face drooping, Arm weakness, Speech difficulty, Time to call EMS."),
    ("Anaphylaxis", "RED", "immune",
     "Severe allergic reaction with airway swelling, hives, hypotension. Epinephrine IM, call EMS."),
    ("Drowning", "RED", "respiratory",
     "Submersion/immersion incident. Remove from water, begin CPR if needed."),
    ("Tension Pneumothorax", "RED", "respiratory",
     "Air trapped in chest cavity. Chest seal if open wound; immediate EMS."),
    ("Opioid Overdose", "RED", "toxicology",
     "Unresponsive, slow/absent breathing, pinpoint pupils. Naloxone + CPR."),
    ("Severe Burns (>20% BSA)", "RED", "trauma",
     "Large area burn. Cool with running water 20 min, wrap loosely, EMS."),

    # YELLOW – Urgent
    ("Moderate Bleeding", "YELLOW", "trauma",
     "Significant but not immediately life-threatening bleeding. Direct pressure, elevation."),
    ("Fracture – Open", "YELLOW", "musculoskeletal",
     "Bone protruding through skin. Do not push back; cover with sterile dressing, splint, EMS."),
    ("Fracture – Closed", "YELLOW", "musculoskeletal",
     "Deformity, swelling, pain. Splint in position found. Ice. Seek medical care."),
    ("Head Injury / Concussion", "YELLOW", "neurological",
     "Loss of consciousness, confusion, vomiting after head trauma. Monitor, EMS if worsening."),
    ("Spinal Injury", "YELLOW", "neurological",
     "Suspected neck/back injury. Do NOT move. Maintain spinal alignment. EMS immediately."),
    ("Seizure", "YELLOW", "neurological",
     "Uncontrolled electrical discharge. Protect from injury, recovery position after. EMS if >5 min."),
    ("Diabetic Emergency – Hypoglycemia", "YELLOW", "endocrine",
     "Low blood sugar: shakiness, confusion, sweating. Give oral glucose 20 g if conscious."),
    ("Diabetic Emergency – Hyperglycemia", "YELLOW", "endocrine",
     "High blood sugar: excessive thirst, frequent urination, fruity breath. Seek medical care."),
    ("Asthma Attack", "YELLOW", "respiratory",
     "Wheezing, difficulty breathing, chest tightness. Assist with prescribed inhaler. EMS if severe."),
    ("Chest Pain – Non-Cardiac", "YELLOW", "cardiovascular",
     "Chest pain without typical cardiac features. Rest, monitor, seek medical evaluation."),
    ("Allergic Reaction – Moderate", "YELLOW", "immune",
     "Hives, swelling, itching without airway compromise. Antihistamine. Monitor for anaphylaxis."),
    ("Hypothermia", "YELLOW", "environmental",
     "Core temp < 35°C. Shivering, confusion. Remove from cold, passive + active rewarming."),
    ("Heatstroke", "YELLOW", "environmental",
     "Core temp > 40°C. Altered mental status, hot skin. Rapid cooling, EMS."),
    ("Heat Exhaustion", "YELLOW", "environmental",
     "Heavy sweating, weakness, nausea, cool/clammy skin. Move to shade, oral fluids, cool."),
    ("Snake Bite", "YELLOW", "environmental",
     "Immobilize limb, remove jewelry. Do NOT tourniquet, cut, or suck. EMS for antivenom."),
    ("Chemical Burn – Skin", "YELLOW", "toxicology",
     "Remove contaminated clothing. Irrigate with large amounts of water 20+ min."),
    ("Chemical Burn – Eye", "YELLOW", "toxicology",
     "Irrigate eye with clean water or saline for at least 20 min. Seek emergency care."),
    ("Abdominal Pain – Severe", "YELLOW", "gastrointestinal",
     "Severe/worsening abdominal pain. Do not give food/water. Position of comfort. Seek care."),
    ("Pneumonia", "YELLOW", "respiratory",
     "Fever, productive cough, difficulty breathing. Rest, fluids, seek medical care."),
    ("Dehydration – Severe", "YELLOW", "gastrointestinal",
     "Minimal urine, dry mouth, rapid heart rate. Oral rehydration solution. EMS if confused."),
    ("Internal Bleeding (Suspected)", "YELLOW", "trauma",
     "Rigid abdomen, bruising, shock signs after trauma. Do NOT give fluids. EMS."),

    # GREEN – Non-urgent
    ("Minor Bleeding / Cuts", "GREEN", "trauma",
     "Small wound. Clean with water, apply antibiotic ointment, cover with bandage."),
    ("Minor Burns (1st Degree)", "GREEN", "trauma",
     "Skin redness, pain, no blisters. Cool running water 10-20 min, aloe vera, OTC pain relief."),
    ("Partial Thickness Burn", "GREEN", "trauma",
     "Blisters present. Cool with water 20 min. Do NOT pop blisters. Cover loosely."),
    ("Sprain", "GREEN", "musculoskeletal",
     "Ligament injury: pain, swelling. RICE: Rest, Ice, Compression, Elevation."),
    ("Strain", "GREEN", "musculoskeletal",
     "Muscle/tendon injury: pain, limited motion. Rest, ice, compression, elevation."),
    ("Nosebleed", "GREEN", "trauma",
     "Epistaxis: sit upright, lean forward, pinch soft part of nose 10-15 min."),
    ("Bee / Wasp Sting", "GREEN", "environmental",
     "Remove stinger by scraping. Ice pack. OTC antihistamine. Watch for anaphylaxis signs."),
    ("Tick Bite", "GREEN", "environmental",
     "Grasp head close to skin with tweezers, pull upward steadily. Clean area. Monitor for rash."),
    ("Spider Bite", "GREEN", "environmental",
     "Clean wound, ice. Seek care if severe pain, muscle cramps, or spreading redness."),
    ("Scorpion Sting", "GREEN", "environmental",
     "Clean area, ice, OTC pain relief. Seek care if severe symptoms. Topical lidocaine helps."),
    ("Jellyfish Sting", "GREEN", "environmental",
     "Rinse with vinegar (box jellyfish) or hot water 40°C. Remove tentacles. Do NOT use fresh water."),
    ("Poison Ivy / Oak / Sumac", "GREEN", "environmental",
     "Wash skin immediately with soap/water. Calamine lotion, antihistamine for itch."),
    ("Frostbite", "GREEN", "environmental",
     "Pale/numb extremities. Warm gradually in 37-39°C water. Do NOT rub. Seek care."),
    ("Sunburn", "GREEN", "environmental",
     "Red, painful skin. Cool compresses, aloe vera, hydrate, ibuprofen for pain."),
    ("Eye Foreign Body", "GREEN", "trauma",
     "Do NOT rub. Flush with clean water. If embedded, cover and seek care."),
    ("Dental Avulsion", "GREEN", "trauma",
     "Handle tooth by crown only. Store in milk or saliva. Replant within 60 min."),
    ("Fainting / Presyncope", "GREEN", "neurological",
     "Lay person flat, elevate legs. Leg-crossing + muscle tensing to abort presyncope."),
    ("Muscle Cramp", "GREEN", "musculoskeletal",
     "Stretch affected muscle, gentle massage, hydrate, electrolytes."),
    ("Diarrhea / Vomiting", "GREEN", "gastrointestinal",
     "Oral rehydration: small frequent sips. Avoid dairy. Seek care if bloody or > 24 hr."),
    ("Fever", "GREEN", "general",
     "Acetaminophen or ibuprofen. Cool compresses. Fluids. Seek care if > 39.4°C or in infants."),
    ("Panic Attack", "GREEN", "psychological",
     "Reassure. Slow breathing: 4 counts in, 4 hold, 4 out. Safe environment."),
    ("Hyperventilation", "GREEN", "respiratory",
     "Slow, controlled breathing. Reassure. Do NOT use paper bag method."),
    ("Wound Infection Signs", "GREEN", "trauma",
     "Increasing redness, warmth, swelling, pus. Clean, seek antibiotics if spreading."),
    ("Blisters", "GREEN", "trauma",
     "Do NOT pop. Protect with moleskin or bandage. If burst, clean and cover."),
    ("Splinter", "GREEN", "trauma",
     "Remove with clean tweezers. Clean area, apply antibiotic ointment."),
    ("Dislocated Joint", "YELLOW", "musculoskeletal",
     "Visible deformity at joint. Do NOT attempt to relocate. Splint in position found. Ice. EMS."),
    ("Crush Injury", "RED", "trauma",
     "Trapped limb. Do NOT release without medical supervision (crush syndrome risk). EMS."),
    ("Electrocution", "RED", "trauma",
     "Ensure source is OFF. Check breathing/pulse. CPR if needed. Treat burns. EMS."),
    ("Near-Drowning Recovery", "YELLOW", "respiratory",
     "Breathing restored after submersion. Monitor closely. Recovery position. EMS for evaluation."),
    ("Open Chest Wound", "RED", "trauma",
     "Leave exposed to air or apply vented chest seal. Do NOT use occlusive dressing. EMS."),
]

# ── Symptom mappings ────────────────────────────────────────────────────
# condition_name → [(symptom, weight), ...]

SYMPTOMS = {
    "Cardiac Arrest": [
        ("no pulse", 3.0), ("not breathing", 3.0), ("unresponsive", 2.5),
        ("collapse", 2.0), ("no heartbeat", 3.0), ("gasping", 1.5),
    ],
    "Heart Attack": [
        ("chest pain", 3.0), ("chest pressure", 3.0), ("left arm pain", 2.5),
        ("jaw pain", 2.0), ("sweating", 1.5), ("nausea", 1.5),
        ("shortness of breath", 2.0), ("dizziness", 1.0),
    ],
    "Severe Bleeding": [
        ("heavy bleeding", 3.0), ("blood spurting", 3.0), ("blood pooling", 3.0),
        ("pale skin", 2.0), ("rapid pulse", 1.5), ("light-headed", 1.5),
        ("wound", 1.0), ("laceration", 2.0),
    ],
    "Choking – Adult": [
        ("cannot breathe", 3.0), ("clutching throat", 3.0), ("cannot speak", 2.5),
        ("turning blue", 2.0), ("gagging", 1.5), ("coughing weakly", 1.0),
    ],
    "Choking – Child": [
        ("cannot breathe", 3.0), ("clutching throat", 3.0), ("cannot speak", 2.5),
        ("turning blue", 2.0), ("gagging", 1.5), ("child choking", 3.0),
    ],
    "Choking – Infant": [
        ("cannot breathe", 3.0), ("turning blue", 2.0), ("silent cry", 2.5),
        ("weak cough", 1.5), ("infant choking", 3.0), ("not crying", 2.0),
    ],
    "Stroke": [
        ("face drooping", 3.0), ("arm weakness", 3.0), ("speech difficulty", 3.0),
        ("sudden numbness", 2.5), ("confusion", 2.0), ("vision loss", 2.0),
        ("severe headache", 2.0), ("loss of balance", 1.5),
    ],
    "Anaphylaxis": [
        ("throat swelling", 3.0), ("difficulty breathing", 3.0), ("hives", 2.5),
        ("swollen face", 2.5), ("rapid pulse", 2.0), ("dizziness", 1.5),
        ("nausea", 1.0), ("allergic reaction", 2.0), ("itching", 1.0),
    ],
    "Drowning": [
        ("submersion", 3.0), ("not breathing", 3.0), ("found in water", 3.0),
        ("blue lips", 2.5), ("unresponsive", 2.5), ("coughing water", 2.0),
    ],
    "Tension Pneumothorax": [
        ("chest wound", 3.0), ("difficulty breathing", 3.0), ("chest pain", 2.5),
        ("tracheal deviation", 2.0), ("distended neck veins", 2.0),
    ],
    "Opioid Overdose": [
        ("unresponsive", 3.0), ("slow breathing", 3.0), ("pinpoint pupils", 3.0),
        ("blue lips", 2.5), ("drug use", 2.0), ("needle marks", 1.5),
    ],
    "Severe Burns (>20% BSA)": [
        ("large burn area", 3.0), ("charred skin", 3.0), ("no pain at burn site", 2.5),
        ("difficulty breathing", 2.0), ("swelling", 1.5),
    ],
    "Moderate Bleeding": [
        ("bleeding", 2.5), ("wound", 2.0), ("cut", 2.0),
        ("blood flow steady", 2.0), ("pain", 1.0),
    ],
    "Fracture – Open": [
        ("bone visible", 3.0), ("bone protruding", 3.0), ("deformity", 2.5),
        ("severe pain", 2.0), ("swelling", 1.5), ("bleeding", 2.0),
    ],
    "Fracture – Closed": [
        ("deformity", 2.5), ("swelling", 2.0), ("severe pain", 2.5),
        ("cannot move limb", 2.0), ("bruising", 1.5), ("heard a snap", 2.0),
    ],
    "Head Injury / Concussion": [
        ("loss of consciousness", 3.0), ("confusion", 2.5), ("headache", 2.0),
        ("vomiting", 2.0), ("dizziness", 1.5), ("blurred vision", 1.5),
        ("hit head", 2.5), ("unequal pupils", 2.5),
    ],
    "Spinal Injury": [
        ("neck pain", 3.0), ("back pain", 2.5), ("tingling extremities", 2.5),
        ("cannot move legs", 3.0), ("numbness", 2.0), ("fall from height", 2.0),
    ],
    "Seizure": [
        ("convulsions", 3.0), ("shaking", 2.5), ("loss of consciousness", 2.0),
        ("staring", 1.5), ("foaming at mouth", 2.0), ("rigid body", 2.0),
    ],
    "Diabetic Emergency – Hypoglycemia": [
        ("shakiness", 2.5), ("sweating", 2.0), ("confusion", 2.5),
        ("hunger", 1.5), ("rapid heartbeat", 1.5), ("pale skin", 1.0),
        ("diabetic", 2.0), ("low blood sugar", 3.0),
    ],
    "Diabetic Emergency – Hyperglycemia": [
        ("excessive thirst", 2.5), ("frequent urination", 2.5),
        ("fruity breath", 3.0), ("nausea", 1.5), ("confusion", 2.0),
        ("diabetic", 2.0), ("high blood sugar", 3.0),
    ],
    "Asthma Attack": [
        ("wheezing", 3.0), ("difficulty breathing", 2.5), ("chest tightness", 2.0),
        ("coughing", 1.5), ("rapid breathing", 1.5), ("cannot speak full sentences", 2.0),
    ],
    "Chest Pain – Non-Cardiac": [
        ("chest pain", 2.0), ("sharp pain", 1.5), ("pain with breathing", 2.0),
        ("pain with movement", 1.5), ("no arm/jaw pain", 1.0),
    ],
    "Allergic Reaction – Moderate": [
        ("hives", 2.5), ("swelling", 2.0), ("itching", 2.0),
        ("rash", 1.5), ("watery eyes", 1.0),
    ],
    "Hypothermia": [
        ("shivering", 2.5), ("confusion", 2.0), ("slurred speech", 2.0),
        ("drowsiness", 1.5), ("cold exposure", 2.0), ("pale skin", 1.5),
        ("slow breathing", 1.5),
    ],
    "Heatstroke": [
        ("hot skin", 3.0), ("no sweating", 2.5), ("confusion", 2.5),
        ("rapid pulse", 2.0), ("headache", 1.5), ("high temperature", 3.0),
    ],
    "Heat Exhaustion": [
        ("heavy sweating", 2.5), ("weakness", 2.0), ("nausea", 1.5),
        ("cool clammy skin", 2.0), ("dizziness", 1.5), ("headache", 1.0),
    ],
    "Snake Bite": [
        ("fang marks", 3.0), ("swelling at bite", 2.5), ("severe pain", 2.0),
        ("bite wound", 2.0), ("nausea", 1.0), ("blurred vision", 1.5),
    ],
    "Chemical Burn – Skin": [
        ("chemical exposure", 3.0), ("skin burning", 2.5), ("redness", 2.0),
        ("blistering", 1.5), ("pain", 1.5),
    ],
    "Chemical Burn – Eye": [
        ("chemical in eye", 3.0), ("eye pain", 2.5), ("eye redness", 2.0),
        ("vision changes", 2.0), ("tearing", 1.5),
    ],
    "Abdominal Pain – Severe": [
        ("severe abdominal pain", 3.0), ("rigid abdomen", 2.5), ("vomiting", 2.0),
        ("fever", 1.5), ("no bowel sounds", 1.5),
    ],
    "Pneumonia": [
        ("fever", 2.0), ("productive cough", 2.5), ("difficulty breathing", 2.0),
        ("chest pain", 1.5), ("fatigue", 1.0),
    ],
    "Dehydration – Severe": [
        ("dry mouth", 2.5), ("minimal urine", 2.5), ("rapid heart rate", 2.0),
        ("sunken eyes", 2.0), ("dizziness", 1.5), ("confusion", 2.0),
    ],
    "Internal Bleeding (Suspected)": [
        ("rigid abdomen", 3.0), ("bruising", 2.0), ("shock signs", 2.5),
        ("abdominal trauma", 2.5), ("blood in stool", 2.0), ("vomiting blood", 3.0),
    ],
    "Minor Bleeding / Cuts": [
        ("small cut", 2.0), ("minor bleeding", 2.5), ("scratch", 1.5),
        ("scrape", 1.5), ("abrasion", 1.5),
    ],
    "Minor Burns (1st Degree)": [
        ("redness", 2.0), ("pain", 1.5), ("no blisters", 1.0),
        ("sunburn", 2.0), ("minor burn", 2.5),
    ],
    "Partial Thickness Burn": [
        ("blisters", 3.0), ("red skin", 2.0), ("severe pain", 2.0),
        ("burn", 2.0), ("wet appearance", 1.5),
    ],
    "Sprain": [
        ("twisted ankle", 2.5), ("swelling", 2.0), ("bruising", 1.5),
        ("pain with movement", 2.0), ("joint instability", 2.0),
    ],
    "Strain": [
        ("muscle pain", 2.5), ("limited motion", 2.0),
        ("swelling", 1.5), ("muscle spasm", 2.0),
    ],
    "Nosebleed": [
        ("bleeding from nose", 3.0), ("nosebleed", 3.0), ("blood from nostril", 2.5),
    ],
    "Bee / Wasp Sting": [
        ("sting", 2.5), ("swelling at site", 2.0), ("pain at site", 2.0),
        ("redness", 1.5), ("stinger visible", 2.0),
    ],
    "Tick Bite": [
        ("tick attached", 3.0), ("tick found", 2.5), ("rash around bite", 2.0),
        ("bite mark", 1.5),
    ],
    "Spider Bite": [
        ("bite mark", 2.0), ("redness", 1.5), ("pain", 2.0),
        ("swelling", 1.5), ("spider seen", 2.5),
    ],
    "Scorpion Sting": [
        ("sting", 2.5), ("severe pain at site", 2.5), ("numbness", 2.0),
        ("tingling", 1.5), ("scorpion seen", 2.5),
    ],
    "Jellyfish Sting": [
        ("tentacle marks", 3.0), ("burning pain", 2.5), ("rash", 2.0),
        ("welts", 2.0), ("ocean exposure", 1.5),
    ],
    "Poison Ivy / Oak / Sumac": [
        ("itchy rash", 2.5), ("blisters", 2.0), ("redness", 1.5),
        ("plant contact", 2.5), ("streaky rash", 2.0),
    ],
    "Frostbite": [
        ("numb fingers", 2.5), ("pale skin", 2.5), ("hard skin", 2.0),
        ("cold exposure", 2.0), ("waxy skin", 2.0), ("tingling", 1.5),
    ],
    "Sunburn": [
        ("red skin", 2.5), ("pain", 2.0), ("peeling", 1.5),
        ("sun exposure", 2.0), ("warm to touch", 1.5),
    ],
    "Eye Foreign Body": [
        ("something in eye", 3.0), ("eye pain", 2.0), ("tearing", 2.0),
        ("redness", 1.5), ("blinking", 1.0),
    ],
    "Dental Avulsion": [
        ("tooth knocked out", 3.0), ("bleeding gums", 2.0), ("tooth missing", 2.5),
        ("facial trauma", 1.5),
    ],
    "Fainting / Presyncope": [
        ("felt faint", 2.5), ("passed out", 3.0), ("light-headed", 2.0),
        ("tunnel vision", 2.0), ("pale", 1.5), ("stood up quickly", 1.5),
    ],
    "Muscle Cramp": [
        ("muscle cramp", 3.0), ("sudden pain", 2.0), ("muscle tightness", 2.0),
        ("cannot relax muscle", 2.0),
    ],
    "Diarrhea / Vomiting": [
        ("diarrhea", 2.5), ("vomiting", 2.5), ("nausea", 2.0),
        ("stomach pain", 1.5), ("cramps", 1.5),
    ],
    "Fever": [
        ("high temperature", 2.5), ("feeling hot", 2.0), ("chills", 2.0),
        ("sweating", 1.5), ("body aches", 1.5),
    ],
    "Panic Attack": [
        ("racing heart", 2.0), ("shortness of breath", 2.0),
        ("shaking", 1.5), ("chest tightness", 1.5), ("fear of dying", 2.5),
        ("tingling hands", 1.5),
    ],
    "Hyperventilation": [
        ("rapid breathing", 3.0), ("tingling", 2.0), ("dizziness", 2.0),
        ("chest tightness", 1.5), ("anxiety", 1.5),
    ],
    "Wound Infection Signs": [
        ("increasing redness", 2.5), ("warmth around wound", 2.5),
        ("pus", 3.0), ("swelling", 2.0), ("fever", 1.5), ("red streaks", 2.5),
    ],
    "Blisters": [
        ("fluid-filled bump", 2.5), ("skin bubble", 2.0), ("friction", 2.0),
        ("pain", 1.0),
    ],
    "Splinter": [
        ("splinter", 3.0), ("wood in skin", 2.5), ("foreign body in skin", 2.5),
        ("pain", 1.0),
    ],
    "Dislocated Joint": [
        ("visible deformity", 3.0), ("cannot move joint", 2.5),
        ("severe pain", 2.0), ("swelling", 1.5), ("popped out", 2.5),
    ],
    "Crush Injury": [
        ("trapped limb", 3.0), ("crushed", 3.0), ("building collapse", 2.5),
        ("numbness below", 2.0), ("swelling", 1.5),
    ],
    "Electrocution": [
        ("electric shock", 3.0), ("burn marks", 2.5), ("unresponsive", 2.0),
        ("muscle spasm", 2.0), ("not breathing", 2.5),
    ],
    "Near-Drowning Recovery": [
        ("rescued from water", 3.0), ("coughing", 2.0), ("breathing now", 1.5),
        ("confused", 2.0), ("chest pain", 1.5),
    ],
    "Open Chest Wound": [
        ("sucking wound", 3.0), ("chest wound", 3.0), ("bubbling blood", 2.5),
        ("difficulty breathing", 2.5), ("chest trauma", 2.5),
    ],
}

# ── Phrase mappings ────────────────────────────────────────────────────
# condition_name → [(user_phrase, canonical_symptom), ...]

PHRASES = {
    "Cardiac Arrest": [
        ("he has no pulse", "no pulse"),
        ("she stopped breathing", "not breathing"),
        ("they collapsed", "collapse"),
        ("not responding", "unresponsive"),
        ("no heartbeat", "no heartbeat"),
        ("heart stopped", "no pulse"),
        ("found them down", "unresponsive"),
    ],
    "Heart Attack": [
        ("my chest hurts", "chest pain"),
        ("feels like an elephant on my chest", "chest pressure"),
        ("pain going down my arm", "left arm pain"),
        ("my jaw hurts and I feel sick", "jaw pain"),
        ("breaking out in a cold sweat", "sweating"),
        ("feel like I might throw up", "nausea"),
        ("hard to breathe", "shortness of breath"),
        ("chest tightness", "chest pressure"),
        ("squeezing in my chest", "chest pressure"),
    ],
    "Severe Bleeding": [
        ("blood is everywhere", "heavy bleeding"),
        ("blood is shooting out", "blood spurting"),
        ("blood won't stop", "heavy bleeding"),
        ("I can see the artery", "blood spurting"),
        ("there's a pool of blood", "blood pooling"),
        ("losing a lot of blood", "heavy bleeding"),
        ("deep cut won't stop bleeding", "heavy bleeding"),
        ("sliced my arm open", "laceration"),
    ],
    "Choking – Adult": [
        ("I can't breathe", "cannot breathe"),
        ("something stuck in my throat", "cannot breathe"),
        ("he's choking", "cannot breathe"),
        ("she can't talk", "cannot speak"),
        ("grabbing his throat", "clutching throat"),
        ("turning blue", "turning blue"),
        ("food stuck", "cannot breathe"),
        ("can't swallow", "cannot breathe"),
    ],
    "Choking – Child": [
        ("my kid is choking", "child choking"),
        ("child can't breathe", "cannot breathe"),
        ("food stuck in child's throat", "child choking"),
        ("kid is gagging", "gagging"),
        ("child turning blue", "turning blue"),
    ],
    "Choking – Infant": [
        ("baby is choking", "infant choking"),
        ("baby can't breathe", "cannot breathe"),
        ("baby swallowed something", "infant choking"),
        ("baby turning blue", "turning blue"),
        ("newborn choking", "infant choking"),
    ],
    "Stroke": [
        ("one side of face is drooping", "face drooping"),
        ("can't lift their arm", "arm weakness"),
        ("slurring words", "speech difficulty"),
        ("suddenly can't see", "vision loss"),
        ("worst headache ever", "severe headache"),
        ("face looks different", "face drooping"),
        ("talking funny", "speech difficulty"),
        ("half the body won't move", "arm weakness"),
        ("suddenly confused", "confusion"),
    ],
    "Anaphylaxis": [
        ("throat is closing up", "throat swelling"),
        ("can't breathe and covered in hives", "difficulty breathing"),
        ("face is swelling up", "swollen face"),
        ("lips are swelling", "swollen face"),
        ("allergic reaction getting worse", "allergic reaction"),
        ("hives all over", "hives"),
        ("need epi pen", "allergic reaction"),
        ("tongue swelling", "throat swelling"),
    ],
    "Drowning": [
        ("fell in the water", "submersion"),
        ("found face down in pool", "found in water"),
        ("pulled from river", "submersion"),
        ("not breathing after swimming", "not breathing"),
        ("blue after being underwater", "blue lips"),
    ],
    "Opioid Overdose": [
        ("overdosed on drugs", "drug use"),
        ("not waking up after taking pills", "unresponsive"),
        ("barely breathing", "slow breathing"),
        ("tiny pupils", "pinpoint pupils"),
        ("found with needle", "needle marks"),
        ("took too many painkillers", "drug use"),
        ("OD'd", "drug use"),
    ],
    "Seizure": [
        ("having a fit", "convulsions"),
        ("shaking all over", "shaking"),
        ("eyes rolled back", "loss of consciousness"),
        ("body is stiff", "rigid body"),
        ("foam coming from mouth", "foaming at mouth"),
        ("thrashing around", "convulsions"),
        ("convulsing", "convulsions"),
        ("epileptic fit", "convulsions"),
    ],
    "Fracture – Open": [
        ("bone sticking out", "bone protruding"),
        ("I can see the bone", "bone visible"),
        ("bone through skin", "bone protruding"),
        ("arm looks bent wrong", "deformity"),
    ],
    "Fracture – Closed": [
        ("might have broken my arm", "severe pain"),
        ("heard a crack", "heard a snap"),
        ("leg is swollen and hurts", "swelling"),
        ("can't move my wrist", "cannot move limb"),
        ("arm looks deformed", "deformity"),
    ],
    "Head Injury / Concussion": [
        ("hit my head", "hit head"),
        ("knocked unconscious", "loss of consciousness"),
        ("seeing stars", "dizziness"),
        ("threw up after hitting head", "vomiting"),
        ("pupils different sizes", "unequal pupils"),
        ("confused after fall", "confusion"),
    ],
    "Spinal Injury": [
        ("can't feel my legs", "cannot move legs"),
        ("tingling in my hands and feet", "tingling extremities"),
        ("fell from a roof", "fall from height"),
        ("neck hurts after car accident", "neck pain"),
        ("back is killing me after fall", "back pain"),
    ],
    "Diabetic Emergency – Hypoglycemia": [
        ("blood sugar is low", "low blood sugar"),
        ("feeling shaky and sweaty", "shakiness"),
        ("diabetic and confused", "confusion"),
        ("need sugar", "low blood sugar"),
        ("sugar dropping", "low blood sugar"),
    ],
    "Diabetic Emergency – Hyperglycemia": [
        ("blood sugar is very high", "high blood sugar"),
        ("so thirsty and peeing a lot", "excessive thirst"),
        ("breath smells fruity", "fruity breath"),
        ("diabetic and sick", "high blood sugar"),
    ],
    "Asthma Attack": [
        ("can't breathe, have asthma", "wheezing"),
        ("wheezing badly", "wheezing"),
        ("chest is tight", "chest tightness"),
        ("need my inhaler", "wheezing"),
        ("asthma flare up", "wheezing"),
    ],
    "Hypothermia": [
        ("been in the cold too long", "cold exposure"),
        ("can't stop shivering", "shivering"),
        ("confused and cold", "confusion"),
        ("lips are blue from cold", "pale skin"),
        ("slurring words and freezing", "slurred speech"),
    ],
    "Heatstroke": [
        ("overheated and confused", "confusion"),
        ("stopped sweating in the heat", "no sweating"),
        ("skin is dry and hot", "hot skin"),
        ("passed out in the sun", "confusion"),
        ("temperature over 104", "high temperature"),
    ],
    "Heat Exhaustion": [
        ("sweating a lot and feel weak", "heavy sweating"),
        ("feel sick in the heat", "nausea"),
        ("skin is cool and clammy", "cool clammy skin"),
        ("dizzy from the heat", "dizziness"),
    ],
    "Snake Bite": [
        ("bitten by a snake", "fang marks"),
        ("snake bit me", "fang marks"),
        ("two puncture wounds", "fang marks"),
        ("arm swelling after snake bite", "swelling at bite"),
    ],
    "Burns (general)": [
        ("got burned", "burn"),
        ("touched something hot", "burn"),
        ("spilled boiling water", "burn"),
        ("flame burn", "burn"),
    ],
    "Nosebleed": [
        ("nose won't stop bleeding", "bleeding from nose"),
        ("blood coming from my nose", "bleeding from nose"),
        ("got hit in the nose", "bleeding from nose"),
    ],
    "Allergic Reaction – Moderate": [
        ("breaking out in hives", "hives"),
        ("something made me itchy", "itching"),
        ("lips slightly swollen", "swelling"),
        ("rash after eating", "rash"),
    ],
    "Bee / Wasp Sting": [
        ("got stung by a bee", "sting"),
        ("wasp stung me", "sting"),
        ("stinger still in", "stinger visible"),
        ("swelling where I got stung", "swelling at site"),
    ],
    "Fainting / Presyncope": [
        ("feel like I'm going to pass out", "felt faint"),
        ("they fainted", "passed out"),
        ("everything went black", "passed out"),
        ("got up too fast and felt dizzy", "stood up quickly"),
    ],
    "Chemical Burn – Skin": [
        ("chemical spilled on my skin", "chemical exposure"),
        ("acid burn on hand", "chemical exposure"),
        ("bleach on my skin", "chemical exposure"),
    ],
    "Chemical Burn – Eye": [
        ("got chemicals in my eye", "chemical in eye"),
        ("eye is burning", "eye pain"),
        ("splashed cleaner in eye", "chemical in eye"),
    ],
    "Minor Bleeding / Cuts": [
        ("small cut on finger", "small cut"),
        ("paper cut", "small cut"),
        ("scraped my knee", "scrape"),
        ("little bit of bleeding", "minor bleeding"),
    ],
    "Minor Burns (1st Degree)": [
        ("skin is red from the stove", "redness"),
        ("small burn no blisters", "minor burn"),
        ("got a sunburn", "sunburn"),
    ],
    "Partial Thickness Burn": [
        ("burn with blisters", "blisters"),
        ("blisters from burn", "blisters"),
        ("second degree burn", "blisters"),
    ],
    "Sprain": [
        ("twisted my ankle", "twisted ankle"),
        ("ankle is swollen", "swelling"),
        ("rolled my ankle", "twisted ankle"),
    ],
    "Strain": [
        ("pulled a muscle", "muscle pain"),
        ("muscle hurts", "muscle pain"),
        ("strained my back", "muscle pain"),
    ],
    "Tick Bite": [
        ("found a tick on me", "tick attached"),
        ("tick embedded in skin", "tick attached"),
        ("bug burrowed in", "tick attached"),
    ],
    "Diarrhea / Vomiting": [
        ("throwing up", "vomiting"),
        ("can't stop vomiting", "vomiting"),
        ("have the runs", "diarrhea"),
        ("stomach bug", "diarrhea"),
    ],
    "Fever": [
        ("running a fever", "high temperature"),
        ("feels really hot", "feeling hot"),
        ("got the chills", "chills"),
        ("temperature is 103", "high temperature"),
    ],
    "Panic Attack": [
        ("I think I'm having a heart attack but I'm young", "racing heart"),
        ("can't catch my breath and I'm scared", "shortness of breath"),
        ("feel like I'm dying", "fear of dying"),
        ("heart racing and shaking", "racing heart"),
    ],
    "Muscle Cramp": [
        ("leg cramp", "muscle cramp"),
        ("charlie horse", "muscle cramp"),
        ("calf won't relax", "cannot relax muscle"),
    ],
    "Eye Foreign Body": [
        ("something in my eye", "something in eye"),
        ("eye hurts and watering", "eye pain"),
        ("dust in my eye", "something in eye"),
    ],
    "Dental Avulsion": [
        ("knocked a tooth out", "tooth knocked out"),
        ("tooth fell out from hit", "tooth knocked out"),
    ],
    "Frostbite": [
        ("fingers are white and numb", "numb fingers"),
        ("toes turned white", "pale skin"),
        ("skin looks waxy", "waxy skin"),
    ],
    "Wound Infection Signs": [
        ("wound looks infected", "increasing redness"),
        ("pus coming from cut", "pus"),
        ("red streaks from wound", "red streaks"),
    ],
    "Crush Injury": [
        ("arm trapped under rubble", "trapped limb"),
        ("pinned under debris", "crushed"),
        ("building fell on leg", "building collapse"),
    ],
    "Electrocution": [
        ("got shocked", "electric shock"),
        ("touched a live wire", "electric shock"),
        ("lightning struck", "electric shock"),
    ],
    "Open Chest Wound": [
        ("hole in chest", "chest wound"),
        ("stabbed in the chest", "chest wound"),
        ("bullet wound in chest", "chest wound"),
        ("air sucking into wound", "sucking wound"),
    ],
    "Dislocated Joint": [
        ("shoulder popped out", "popped out"),
        ("knee looks wrong", "visible deformity"),
        ("finger jammed and bent", "visible deformity"),
    ],
    "Poison Ivy / Oak / Sumac": [
        ("itchy rash after hiking", "plant contact"),
        ("blisters after touching plants", "blisters"),
        ("rash in streaks", "streaky rash"),
    ],
    "Sunburn": [
        ("skin is really red from the sun", "red skin"),
        ("sunburned and peeling", "peeling"),
    ],
    "Spider Bite": [
        ("think a spider bit me", "spider seen"),
        ("two small marks on skin", "bite mark"),
    ],
    "Scorpion Sting": [
        ("stung by scorpion", "sting"),
        ("scorpion got me", "scorpion seen"),
    ],
    "Jellyfish Sting": [
        ("jellyfish wrapped around my arm", "tentacle marks"),
        ("stung in the ocean", "ocean exposure"),
    ],
    "Abdominal Pain – Severe": [
        ("stomach is rock hard", "rigid abdomen"),
        ("worst belly pain ever", "severe abdominal pain"),
    ],
    "Pneumonia": [
        ("coughing up green stuff", "productive cough"),
        ("hard to breathe with fever", "difficulty breathing"),
    ],
    "Dehydration – Severe": [
        ("haven't peed all day", "minimal urine"),
        ("mouth is so dry", "dry mouth"),
    ],
    "Internal Bleeding (Suspected)": [
        ("belly hard after car wreck", "rigid abdomen"),
        ("throwing up blood", "vomiting blood"),
        ("blood in stool", "blood in stool"),
    ],
    "Near-Drowning Recovery": [
        ("pulled them out and they're breathing", "rescued from water"),
        ("coughing after being in water", "coughing"),
    ],
    "Hyperventilation": [
        ("breathing too fast", "rapid breathing"),
        ("hands are tingling", "tingling"),
    ],
    "Blisters": [
        ("skin bubble from shoes", "skin bubble"),
        ("blister on heel", "fluid-filled bump"),
    ],
    "Splinter": [
        ("got a splinter", "splinter"),
        ("wood stuck in finger", "wood in skin"),
    ],
    "Severe Burns (>20% BSA)": [
        ("whole body burned", "large burn area"),
        ("skin is black from fire", "charred skin"),
    ],
    "Tension Pneumothorax": [
        ("sucking chest wound", "chest wound"),
        ("can't breathe after being stabbed in chest", "difficulty breathing"),
    ],
}

# ── Decision trees ──────────────────────────────────────────────────────
# Each tree is a JSON structure: { question, options: [{ label, next }] }
# 'next' can be another question node or an outcome node { outcome, triage }

def _q(text, options):
    """Build a question node."""
    return {"question": text, "options": options}

def _o(label, next_node):
    """Build an option."""
    return {"label": label, "next": next_node}

def _outcome(text, triage):
    """Build an outcome node."""
    return {"outcome": text, "triage": triage}


DECISION_TREES = {
    "Cardiac Arrest": _q("Is the person responsive?", [
        _o("No – not breathing / no pulse", _q("Do you have an AED?", [
            _o("Yes", _outcome("Begin CPR + use AED. Call EMS immediately.", "RED")),
            _o("No", _outcome("Begin CPR: 30 compressions, 2 breaths. Call EMS.", "RED")),
        ])),
        _o("Yes – responsive", _outcome("Not cardiac arrest. Monitor and reassess symptoms.", "YELLOW")),
    ]),

    "Heart Attack": _q("Is there chest pain or pressure?", [
        _o("Yes", _q("Does the person have aspirin allergy?", [
            _o("No allergy", _outcome("Chew aspirin 325 mg. Call EMS. Rest in comfortable position.", "RED")),
            _o("Yes / unknown", _outcome("Do NOT give aspirin. Call EMS. Rest in comfortable position.", "RED")),
        ])),
        _o("No chest pain", _outcome("Monitor symptoms. Consider other causes.", "YELLOW")),
    ]),

    "Severe Bleeding": _q("Is the bleeding from an extremity?", [
        _o("Yes – arm or leg", _q("Is direct pressure controlling the bleeding?", [
            _o("Yes", _outcome("Maintain direct pressure. Elevate. Call EMS.", "RED")),
            _o("No – bleeding continues", _outcome("Apply tourniquet 5-7 cm above wound. Note time. Call EMS.", "RED")),
        ])),
        _o("No – torso/neck/head", _outcome("Apply firm direct pressure. Pack wound if possible. Call EMS.", "RED")),
    ]),

    "Choking – Adult": _q("Can the person cough, speak, or breathe?", [
        _o("Yes – mild obstruction", _outcome("Encourage forceful coughing. Monitor.", "YELLOW")),
        _o("No – severe obstruction", _q("Is the person conscious?", [
            _o("Yes", _outcome("5 back blows + 5 abdominal thrusts. Repeat until clear or unconscious.", "RED")),
            _o("No", _outcome("Lower to ground. Begin CPR. Check mouth for object before breaths.", "RED")),
        ])),
    ]),

    "Choking – Child": _q("Can the child cough or speak?", [
        _o("Yes – mild", _outcome("Encourage coughing. Do NOT perform thrusts.", "YELLOW")),
        _o("No – severe", _outcome("5 back blows + 5 abdominal thrusts (child > 1 yr). Call EMS.", "RED")),
    ]),

    "Choking – Infant": _q("Is the infant responsive?", [
        _o("Yes – choking", _outcome("5 back thumps + 5 chest compressions. Repeat. Call EMS.", "RED")),
        _o("No – unresponsive", _outcome("Begin infant CPR. Check mouth before breaths. Call EMS.", "RED")),
    ]),

    "Stroke": _q("Apply FAST – is there Face drooping, Arm weakness, or Speech difficulty?", [
        _o("Yes – one or more FAST signs", _q("When did symptoms start?", [
            _o("Within last 4.5 hours", _outcome("Call EMS IMMEDIATELY. Note time of onset. Do NOT give food/drink.", "RED")),
            _o("Unknown / over 4.5 hours", _outcome("Call EMS. Note any time symptom was witnessed. Recovery position if needed.", "RED")),
        ])),
        _o("No FAST signs", _outcome("Monitor. Consider other neurological causes.", "YELLOW")),
    ]),

    "Anaphylaxis": _q("Does the person have an epinephrine auto-injector?", [
        _o("Yes", _outcome("Help administer epi into outer thigh. Call EMS. Second dose in 5-15 min if no improvement.", "RED")),
        _o("No", _q("Is the person having difficulty breathing?", [
            _o("Yes", _outcome("Call EMS. Position upright. If becomes unresponsive, begin CPR.", "RED")),
            _o("No – but hives/swelling", _outcome("Call EMS. Monitor airway closely. Antihistamine if available.", "YELLOW")),
        ])),
    ]),

    "Drowning": _q("Is the person breathing?", [
        _o("No", _outcome("Begin CPR (rescue breaths first). Call EMS. Continue until help arrives.", "RED")),
        _o("Yes – breathing", _outcome("Recovery position. Monitor. Keep warm. EMS for evaluation.", "YELLOW")),
    ]),

    "Opioid Overdose": _q("Is the person responsive?", [
        _o("No – unresponsive", _q("Do you have naloxone (Narcan)?", [
            _o("Yes", _outcome("Administer naloxone. Begin CPR. Call EMS. Repeat naloxone every 2-3 min.", "RED")),
            _o("No", _outcome("Begin CPR with rescue breaths. Call EMS.", "RED")),
        ])),
        _o("Yes – responsive", _outcome("Call EMS. Monitor breathing closely. Recovery position.", "YELLOW")),
    ]),

    "Seizure": _q("Is the seizure currently happening?", [
        _o("Yes – actively seizing", _q("Has it lasted more than 5 minutes?", [
            _o("Yes or uncertain", _outcome("Call EMS. Protect from injury. Do NOT restrain. Time the seizure.", "RED")),
            _o("No – under 5 min", _outcome("Protect from injury. Clear area. Time it. Recovery position after.", "YELLOW")),
        ])),
        _o("No – seizure has stopped", _outcome("Recovery position. Monitor breathing. Call EMS if first-time seizure.", "YELLOW")),
    ]),

    "Hypothermia": _q("Is the person responsive?", [
        _o("Yes – shivering/confused", _outcome("Remove from cold. Remove wet clothing. Warm blankets/body heat. Warm sweet drinks.", "YELLOW")),
        _o("No – unresponsive", _outcome("Call EMS. Handle gently. Warm slowly. Check breathing – CPR if needed.", "RED")),
    ]),

    "Heatstroke": _q("Is the person responsive?", [
        _o("No / confused", _outcome("Call EMS. Rapid cooling: remove clothes, wet skin, fan. Ice to neck/armpits/groin.", "RED")),
        _o("Yes – alert", _outcome("Move to shade/cool area. Remove excess clothing. Cool with water. Sip fluids.", "YELLOW")),
    ]),

    "Head Injury / Concussion": _q("Did the person lose consciousness?", [
        _o("Yes", _outcome("Call EMS. Do NOT move if spinal injury suspected. Monitor airway.", "RED")),
        _o("No", _q("Is there vomiting, unequal pupils, or worsening confusion?", [
            _o("Yes – danger signs", _outcome("Call EMS. Keep still. Monitor closely.", "RED")),
            _o("No – mild symptoms", _outcome("Rest. Ice to injury. Monitor for 24 hrs. Seek care if symptoms worsen.", "YELLOW")),
        ])),
    ]),

    "Spinal Injury": _q("Can the person feel and move all extremities?", [
        _o("No – numbness/paralysis", _outcome("Do NOT move. Stabilize head/neck. Call EMS immediately.", "RED")),
        _o("Yes – but neck/back pain", _outcome("Minimize movement. Support head. Call EMS. Do NOT twist.", "YELLOW")),
    ]),

    "Asthma Attack": _q("Does the person have a prescribed inhaler?", [
        _o("Yes", _outcome("Assist with inhaler: 4 puffs, wait 4 min. Repeat up to 3 times. Sit upright.", "YELLOW")),
        _o("No", _q("Can they speak full sentences?", [
            _o("No – severe", _outcome("Call EMS. Sit upright, lean slightly forward. Stay calm.", "RED")),
            _o("Yes – mild", _outcome("Sit upright. Slow breathing. Seek medical care.", "YELLOW")),
        ])),
    ]),

    "Fracture – Open": _q("Is there severe bleeding?", [
        _o("Yes", _outcome("Control bleeding with pressure around (not on) bone. Cover with sterile dressing. Call EMS.", "RED")),
        _o("No – or minimal", _outcome("Cover wound. Splint in position found. Do NOT push bone back. Call EMS.", "YELLOW")),
    ]),

    "Fracture – Closed": _q("Is there deformity or inability to use the limb?", [
        _o("Yes", _outcome("Splint in position found. Apply ice (over cloth). Elevate if possible. Seek care.", "YELLOW")),
        _o("No – just pain/swelling", _outcome("Ice, elevate, rest. Seek care for X-ray.", "GREEN")),
    ]),

    "Snake Bite": _q("Are there fang marks or swelling at the bite?", [
        _o("Yes", _outcome("Immobilize bitten limb at/below heart level. Remove jewelry. Mark swelling edge. Call EMS.", "YELLOW")),
        _o("No – uncertain", _outcome("Clean wound. Immobilize. Seek medical evaluation. Do NOT cut, suck, or tourniquet.", "YELLOW")),
    ]),

    "Minor Burns (1st Degree)": _q("Is the burn area larger than the person's palm?", [
        _o("No – small area", _outcome("Cool under running water 10-20 min. Aloe vera. OTC pain relief.", "GREEN")),
        _o("Yes – larger", _outcome("Cool running water 20 min. Cover loosely. Seek medical care if needed.", "GREEN")),
    ]),

    "Partial Thickness Burn": _q("Are blisters intact?", [
        _o("Yes", _outcome("Cool with water 20 min. Do NOT pop blisters. Cover loosely. Seek care.", "GREEN")),
        _o("No – blisters burst", _outcome("Cool with water. Clean gently. Apply ointment. Cover. Seek medical care.", "YELLOW")),
    ]),

    "Severe Burns (>20% BSA)": _q("Is the person breathing?", [
        _o("Yes", _outcome("Cool with water (avoid hypothermia). Cover loosely. Elevate burned limbs. Call EMS.", "RED")),
        _o("No", _outcome("Check airway. Begin CPR if needed. Call EMS. Do NOT cool if hypothermic.", "RED")),
    ]),

    "Nosebleed": _q("Has the nosebleed been going for over 20 minutes?", [
        _o("No", _outcome("Sit upright, lean forward. Pinch soft part of nose 10-15 min without releasing.", "GREEN")),
        _o("Yes – or very heavy", _outcome("Continue pinching. Seek medical care if not stopping.", "YELLOW")),
    ]),

    "Sprain": _q("Can you bear weight on the joint?", [
        _o("Yes – with pain", _outcome("RICE: Rest, Ice 20 min, Compression wrap, Elevate. OTC pain relief.", "GREEN")),
        _o("No – cannot bear weight", _outcome("Immobilize. Ice. Elevate. Seek medical evaluation (possible fracture).", "YELLOW")),
    ]),

    "Bee / Wasp Sting": _q("Are there signs of allergic reaction (hives, swelling, difficulty breathing)?", [
        _o("Yes", _outcome("This may be anaphylaxis. Give epinephrine if available. Call EMS.", "RED")),
        _o("No – local reaction only", _outcome("Remove stinger by scraping. Ice. Antihistamine. OTC pain relief.", "GREEN")),
    ]),

    "Fainting / Presyncope": _q("Is the person conscious now?", [
        _o("Yes – feeling faint", _outcome("Lie down, elevate legs. Loosen tight clothing. Cool cloth on forehead.", "GREEN")),
        _o("No – still unconscious", _outcome("Recovery position. Check breathing. Call EMS if not waking within 1 min.", "YELLOW")),
    ]),

    "Diabetic Emergency – Hypoglycemia": _q("Is the person conscious and able to swallow?", [
        _o("Yes", _outcome("Give 20 g oral glucose (glucose tabs, juice, or sugar). Recheck in 15 min.", "YELLOW")),
        _o("No – unconscious", _outcome("Do NOT put anything in mouth. Call EMS. Recovery position.", "RED")),
    ]),

    "Diabetic Emergency – Hyperglycemia": _q("Is the person confused or vomiting?", [
        _o("Yes", _outcome("Call EMS. Do NOT give insulin (risk of error). Keep comfortable.", "YELLOW")),
        _o("No – alert", _outcome("Encourage water intake. Seek medical care for glucose management.", "YELLOW")),
    ]),

    "Allergic Reaction – Moderate": _q("Is there any difficulty breathing or throat tightness?", [
        _o("Yes", _outcome("This may be progressing to anaphylaxis. Give epi if available. Call EMS.", "RED")),
        _o("No", _outcome("Oral antihistamine (diphenhydramine 25-50 mg). Monitor for progression.", "GREEN")),
    ]),

    "Chemical Burn – Skin": _q("Is the chemical still on the skin?", [
        _o("Yes / unknown", _outcome("Remove contaminated clothing. Irrigate with water for 20+ min. Call EMS.", "YELLOW")),
        _o("No – already washed off", _outcome("Ensure thorough decontamination. Cover loosely. Seek medical care.", "YELLOW")),
    ]),

    "Chemical Burn – Eye": _q("Has the eye been flushed?", [
        _o("No", _outcome("Immediately flush with clean water for 20 min. Hold eyelid open. Seek emergency care.", "YELLOW")),
        _o("Yes – already flushed", _outcome("Continue flushing if < 20 min elapsed. Seek emergency eye care.", "YELLOW")),
    ]),

    "Crush Injury": _q("How long has the limb been trapped?", [
        _o("Less than 1 hour", _outcome("Call EMS before release. Tourniquet may be needed. Monitor for shock.", "RED")),
        _o("More than 1 hour", _outcome("DO NOT release without EMS. Crush syndrome risk. IV fluids needed before release.", "RED")),
    ]),

    "Electrocution": _q("Is the power source still active?", [
        _o("Yes / Unknown", _outcome("Do NOT touch victim. Turn off power. Call EMS.", "RED")),
        _o("No – safely disconnected", _q("Is the person breathing?", [
            _o("No", _outcome("Begin CPR. Call EMS. Treat burns.", "RED")),
            _o("Yes", _outcome("Check for burns (entry/exit). Call EMS. Monitor heart rhythm.", "YELLOW")),
        ])),
    ]),

    "Open Chest Wound": _q("Is air being sucked into the wound?", [
        _o("Yes – sucking wound", _outcome("Apply vented chest seal or leave open. Do NOT use occlusive dressing. Call EMS.", "RED")),
        _o("No / Not sure", _outcome("Cover with clean non-occlusive dressing. Call EMS. Monitor breathing.", "RED")),
    ]),

    "Tension Pneumothorax": _q("Is there a chest wound?", [
        _o("Yes", _outcome("Apply vented chest seal. If no seal available, leave wound open. Call EMS.", "RED")),
        _o("No – closed injury", _outcome("Call EMS immediately. Position upright if breathing. Monitor closely.", "RED")),
    ]),

    "Diarrhea / Vomiting": _q("Is there blood in vomit or stool?", [
        _o("Yes", _outcome("Seek medical care. Possible internal bleeding. Do NOT eat. Small sips of water.", "YELLOW")),
        _o("No", _outcome("Oral rehydration: small frequent sips. Avoid dairy. Seek care if > 24 hrs.", "GREEN")),
    ]),

    "Fever": _q("Is the temperature above 39.4°C (103°F)?", [
        _o("Yes – or infant < 3 months with any fever", _outcome("Seek medical care promptly. Acetaminophen/ibuprofen. Cool compresses.", "YELLOW")),
        _o("No – mild fever", _outcome("Rest, fluids. Acetaminophen/ibuprofen. Monitor.", "GREEN")),
    ]),

    "Dehydration – Severe": _q("Is the person confused or unable to drink?", [
        _o("Yes", _outcome("Call EMS. Do NOT force fluids if unable to swallow. Position of comfort.", "YELLOW")),
        _o("No – can drink", _outcome("Oral rehydration solution. Small frequent sips. Rest in cool area.", "GREEN")),
    ]),

    "Frostbite": _q("Is the skin hard and numb?", [
        _o("Yes – deep frostbite", _outcome("Warm in 37-39°C water. Do NOT rub or use dry heat. Seek medical care.", "YELLOW")),
        _o("No – superficial", _outcome("Gently warm. Move to warm area. Protect from further cold.", "GREEN")),
    ]),

    "Dislocated Joint": _q("Is there visible deformity at the joint?", [
        _o("Yes", _outcome("Splint in position found. Ice. Do NOT try to relocate. Seek medical care.", "YELLOW")),
        _o("No – just severe pain", _outcome("Immobilize. Ice. Seek X-ray to rule out fracture.", "YELLOW")),
    ]),

    "Panic Attack": _q("Are there chest pains or difficulty breathing?", [
        _o("Yes – could be cardiac", _outcome("Rule out heart attack first. If confirmed panic: slow breathing 4-4-4.", "YELLOW")),
        _o("No – anxiety symptoms", _outcome("Reassure. Slow breathing: 4 in, 4 hold, 4 out. Safe environment.", "GREEN")),
    ]),

    "Abdominal Pain – Severe": _q("Is the abdomen rigid or distended?", [
        _o("Yes", _outcome("Possible surgical emergency. Call EMS. Nothing by mouth. Position of comfort.", "RED")),
        _o("No", _outcome("Rest. No food until evaluated. Seek medical care. Note location of pain.", "YELLOW")),
    ]),

    "Internal Bleeding (Suspected)": _q("Are there signs of shock (pale, rapid pulse, confusion)?", [
        _o("Yes", _outcome("Call EMS. Elevate legs (if no spinal injury). Keep warm. Nothing by mouth.", "RED")),
        _o("No – but suspected internal injury", _outcome("Call EMS. Monitor closely. Nothing by mouth. Rest.", "YELLOW")),
    ]),

    "Near-Drowning Recovery": _q("Is the person fully conscious?", [
        _o("Yes – alert", _outcome("Recovery position. Monitor for delayed symptoms. Warm blankets. EMS evaluation.", "YELLOW")),
        _o("No – drowsy/confused", _outcome("Recovery position. Call EMS. Monitor breathing. Keep warm.", "YELLOW")),
    ]),

    "Pneumonia": _q("Is there severe difficulty breathing?", [
        _o("Yes", _outcome("Call EMS. Sit upright. Do NOT lie flat. Monitor oxygen.", "YELLOW")),
        _o("No – mild", _outcome("Rest, fluids, OTC fever reducer. Seek medical care for antibiotics.", "GREEN")),
    ]),
}

# If a condition does not have a tree, we generate a simple one from its summary
def _default_tree(cond_name, summary, triage):
    return _q(f"Suspected {cond_name}. Is the person stable?", [
        _o("Yes", _outcome(f"{summary} Monitor and seek care if worsening.", "GREEN" if triage == "GREEN" else "YELLOW")),
        _o("No – worsening", _outcome(f"Call EMS. {summary}", triage)),
    ])


# ── Protocol steps ──────────────────────────────────────────────────────
# condition_name → [(step_title, step_detail, warning_or_none), ...]

PROTOCOLS = {
    "Cardiac Arrest": [
        ("Check Safety", "Ensure the scene is safe before approaching.", None),
        ("Check Responsiveness", "Tap shoulders firmly and shout 'Are you OK?'", None),
        ("Call EMS", "Call emergency services or ask bystander to call. Request AED.", None),
        ("Open Airway", "Head-tilt chin-lift. Look for chest rise.", None),
        ("Begin Compressions", "Push hard and fast center of chest. 5-6 cm depth. Rate 100-120/min.", None),
        ("Give Rescue Breaths", "After 30 compressions, give 2 breaths (1 second each). Watch for chest rise.", "Skip breaths if untrained – compressions only."),
        ("Use AED", "Turn on. Follow voice prompts. Apply pads. 'Clear' before shock.", None),
        ("Continue CPR", "Continue 30:2 cycles until EMS arrives, AED advises, or person recovers.", "Do NOT stop CPR unless trained help takes over."),
    ],
    "Heart Attack": [
        ("Recognize Symptoms", "Chest pain/pressure, arm/jaw pain, sweating, nausea, shortness of breath.", None),
        ("Call EMS", "Call emergency services immediately.", None),
        ("Chew Aspirin", "If no aspirin allergy: chew and swallow 1 adult aspirin (325 mg) or 4 baby aspirin (81 mg each).", "Do NOT give aspirin if allergic or advised against by doctor."),
        ("Rest", "Sit or lie in comfortable position. Loosen tight clothing.", None),
        ("Monitor", "Stay with person. Monitor breathing. Be ready to start CPR.", None),
        ("Nitroglycerin", "If prescribed, help person take their nitroglycerin.", "Only help with person's OWN prescribed nitroglycerin."),
        ("Do NOT", "Do NOT let person eat, drink (except aspirin), or exert themselves.", None),
        ("Reassure", "Stay calm. Reassure the person. Help arrives soon.", None),
    ],
    "Severe Bleeding": [
        ("Scene Safety", "Put on gloves if available. Ensure scene is safe.", None),
        ("Expose the Wound", "Remove or cut clothing to see the wound clearly.", None),
        ("Apply Direct Pressure", "Use clean cloth or gauze. Press firmly with both hands.", "Do NOT remove cloths – add more on top if soaked through."),
        ("Elevate", "If extremity, elevate above heart level while maintaining pressure.", None),
        ("Tourniquet", "If extremity bleeding not controlled: apply tourniquet 5-7 cm above wound.", "Note time of tourniquet application. Do NOT remove once applied."),
        ("Pack Wound", "For junctional wounds (groin, armpit, neck): pack with gauze and apply pressure.", None),
        ("Call EMS", "Ensure EMS has been called. Provide wound location and blood loss estimate.", None),
        ("Monitor for Shock", "Watch for pale skin, rapid pulse, confusion. Keep person warm.", None),
    ],
    "Choking – Adult": [
        ("Ask", "Ask 'Are you choking? Can you speak?'", None),
        ("Position", "Stand behind the person. Wrap arms around waist.", None),
        ("Back Blows", "Give 5 sharp back blows between shoulder blades with heel of hand.", None),
        ("Abdominal Thrusts", "Make fist above navel. Grasp with other hand. Thrust inward and upward 5 times.", "For pregnant or obese: chest thrusts instead (arms under armpits)."),
        ("Repeat", "Alternate 5 back blows and 5 abdominal thrusts until object clears.", None),
        ("If Unconscious", "Lower to ground. Call EMS. Begin CPR.", None),
        ("Check Mouth", "Before each breath, look in mouth for visible object. Remove if seen.", "Do NOT perform blind finger sweep."),
        ("Continue", "Continue until object expelled, person breathes, or EMS arrives.", None),
    ],
    "Stroke": [
        ("FAST Check", "Face: smile – is one side drooping? Arms: raise both – does one drift? Speech: repeat a phrase – is it slurred?", None),
        ("Note Time", "Record EXACT time symptoms were first noticed. Critical for treatment.", None),
        ("Call EMS", "Call emergency services. Tell them you suspect stroke.", None),
        ("Position", "If conscious: sit upright supported. If unconscious: recovery position.", None),
        ("Nothing by Mouth", "Do NOT give food, drink, or medication.", "Swallowing may be impaired."),
        ("Monitor", "Watch breathing and consciousness. Be ready for CPR.", None),
        ("Reassure", "Speak calmly. Tell them help is coming.", None),
        ("Record", "Note all symptoms and their exact onset times for EMS.", None),
    ],
    "Anaphylaxis": [
        ("Identify", "Sudden hives, face/throat swelling, difficulty breathing, dizziness after exposure.", None),
        ("Epinephrine", "Administer auto-injector into outer mid-thigh. Can inject through clothing.", "Do NOT delay epinephrine. It is the PRIMARY treatment."),
        ("Call EMS", "Call emergency services even if symptoms improve.", None),
        ("Position", "Sitting upright if difficulty breathing. Flat with legs elevated if dizzy/faint.", None),
        ("Second Dose", "If no improvement in 5-15 minutes, give second epinephrine dose.", None),
        ("Remove Trigger", "Remove stinger (scrape, don't squeeze). Stop exposure to allergen.", None),
        ("Monitor", "Watch for breathing changes. Be ready for CPR.", None),
        ("Antihistamine", "Oral diphenhydramine 25-50 mg as adjunct ONLY. NOT a substitute for epinephrine.", "Antihistamines do NOT treat airway swelling."),
    ],
    "Seizure": [
        ("Time It", "Note when the seizure started. Duration is critical.", None),
        ("Clear Area", "Move dangerous objects away. Create space around person.", None),
        ("Protect Head", "Place something soft under head. Do NOT restrain.", "Do NOT put anything in the mouth."),
        ("Turn on Side", "Once jerking stops, place in recovery position.", None),
        ("Call EMS", "Call if: seizure > 5 min, first-time seizure, doesn't wake, pregnant, in water.", None),
        ("Stay With Them", "Remain until fully conscious. Speak calmly.", None),
    ],
    "Hypothermia": [
        ("Move to Warmth", "Get person out of cold environment. Shelter from wind.", None),
        ("Remove Wet Clothing", "Replace with dry clothing or blankets.", None),
        ("Insulate", "Wrap in blankets. Cover head. Use vapor barrier if available.", None),
        ("Active Warming", "Hot water bottles or warm packs to neck, armpits, groin (over cloth).", "Do NOT apply direct heat. Risk of burns on cold skin."),
        ("Warm Drinks", "If conscious and can swallow: warm sweet drink. No alcohol or caffeine.", None),
        ("Handle Gently", "Rough handling can trigger cardiac arrest in severe hypothermia.", "Do NOT rub extremities."),
        ("Monitor", "Check breathing. CPR if needed. Call EMS for moderate/severe.", None),
    ],
    "Heatstroke": [
        ("Move to Cool Area", "Shade or air-conditioned space.", None),
        ("Remove Clothing", "Remove excess clothing.", None),
        ("Cool Rapidly", "Wet skin with water and fan. Ice packs to neck, armpits, groin.", None),
        ("Immerse if Possible", "Cold water immersion is most effective cooling method.", "Monitor closely – do NOT leave unattended in water."),
        ("Call EMS", "Heatstroke is life-threatening. EMS needed.", None),
        ("Do NOT Give Fluids", "If confused or vomiting, nothing by mouth.", None),
        ("Monitor", "Check temperature if possible. Target < 39°C. Watch for seizures.", None),
    ],
    "Choking – Infant": [
        ("Confirm Choking", "Infant cannot cry, cough, or breathe. May turn blue.", None),
        ("Position Face Down", "Place infant face down on forearm, supporting head. Lower head below trunk.", None),
        ("Back Thumps", "Give 5 firm back thumps between shoulder blades with heel of hand.", None),
        ("Flip Over", "Turn infant face up, supporting head and neck.", None),
        ("Chest Compressions", "Give 5 chest compressions using 2 fingers on breastbone just below nipple line.", "Do NOT use abdominal thrusts on infants."),
        ("Repeat", "Continue alternating 5 back thumps and 5 chest compressions.", None),
        ("If Unconscious", "Begin infant CPR. Call EMS. Check mouth before each breath.", None),
    ],
    "Opioid Overdose": [
        ("Check Responsiveness", "Shout name, sternal rub. Look for breathing.", None),
        ("Call EMS", "Call emergency services immediately.", None),
        ("Naloxone", "Administer 4 mg intranasal or 0.4 mg IM. One nostril or outer thigh.", None),
        ("Begin CPR", "If not breathing: 30 compressions + 2 breaths. Include rescue breaths.", "Ventilation is critical in opioid overdose."),
        ("Repeat Naloxone", "If no response in 2-3 minutes, give second dose of naloxone.", None),
        ("Recovery Position", "When breathing resumes, place in recovery position. Monitor.", None),
        ("Stay", "Stay with person. They may stop breathing again when naloxone wears off.", None),
    ],
    "Snake Bite": [
        ("Move Away", "Get safely away from the snake. Do NOT try to catch it.", None),
        ("Keep Still", "Immobilize bitten limb. Keep at or slightly below heart level.", None),
        ("Remove Constrictions", "Remove rings, watches, tight clothing near bite before swelling.", None),
        ("Mark Swelling", "Use pen to mark edge of swelling with time. Track progression.", None),
        ("Call EMS", "Antivenom may be needed. Transport to hospital.", None),
        ("Do NOT", "Do NOT cut, suck, tourniquet, ice, or electric shock the bite.", "All of these are ineffective and potentially harmful."),
    ],
}

# ── Medications ─────────────────────────────────────────────────────────
# condition_name → [(name, dose, route, notes), ...]

MEDICATIONS = {
    "Heart Attack": [
        ("Aspirin", "325 mg (or 4 x 81 mg)", "Oral – chew", "Only if no aspirin allergy. Chew for faster absorption."),
        ("Nitroglycerin", "0.4 mg sublingual", "Sublingual", "Only person's OWN prescription. May repeat x3 at 5 min intervals."),
    ],
    "Anaphylaxis": [
        ("Epinephrine auto-injector", "0.3 mg (adult) / 0.15 mg (child)", "IM – outer thigh", "PRIMARY treatment. Do NOT delay. Can repeat in 5-15 min."),
        ("Diphenhydramine", "25-50 mg", "Oral", "Adjunct only. Does NOT treat airway swelling."),
    ],
    "Asthma Attack": [
        ("Salbutamol (Albuterol)", "4 puffs via MDI + spacer", "Inhaled", "Person's own prescribed inhaler. Wait 4 min between rounds."),
    ],
    "Diabetic Emergency – Hypoglycemia": [
        ("Oral glucose", "20 g (glucose tabs or gel)", "Oral", "If conscious and able to swallow. Recheck in 15 min."),
        ("Glucagon", "1 mg", "IM or intranasal", "If unconscious. By trained responder only."),
    ],
    "Seizure": [
        ("Midazolam", "10 mg buccal or intranasal", "Buccal/IN", "For prolonged seizure > 5 min if prescribed. By trained responder."),
    ],
    "Opioid Overdose": [
        ("Naloxone (Narcan)", "4 mg intranasal or 0.4 mg IM", "Intranasal / IM", "May repeat every 2-3 min. Person may re-sedate when naloxone wears off."),
    ],
    "Minor Burns (1st Degree)": [
        ("Ibuprofen", "400 mg", "Oral", "For pain and inflammation."),
        ("Aloe vera gel", "Apply thin layer", "Topical", "Soothing. Avoid on broken skin."),
    ],
    "Fever": [
        ("Acetaminophen", "500-1000 mg (adult)", "Oral", "Every 4-6 hrs. Max 4 g/day."),
        ("Ibuprofen", "200-400 mg (adult)", "Oral", "Every 6-8 hrs with food."),
    ],
    "Bee / Wasp Sting": [
        ("Diphenhydramine", "25-50 mg", "Oral", "For local reaction/itching."),
        ("Hydrocortisone cream", "1%", "Topical", "For local swelling."),
    ],
    "Allergic Reaction – Moderate": [
        ("Diphenhydramine", "25-50 mg", "Oral", "Watch for drowsiness."),
        ("Cetirizine", "10 mg", "Oral", "Non-drowsy alternative."),
    ],
    "Sprain": [
        ("Ibuprofen", "400 mg", "Oral", "For pain and swelling. Every 6-8 hrs."),
    ],
    "Minor Bleeding / Cuts": [
        ("Triple antibiotic ointment", "Thin layer", "Topical", "After cleaning wound. Before bandaging."),
    ],
    "Nosebleed": [],  # No medications, just procedural
    "Hypothermia": [],  # Warming, not meds
    "Heatstroke": [],  # Cooling, not meds
    "Poison Ivy / Oak / Sumac": [
        ("Calamine lotion", "Apply as needed", "Topical", "For itching relief."),
        ("Diphenhydramine", "25-50 mg", "Oral", "For severe itching."),
        ("Hydrocortisone cream", "1%", "Topical", "For inflammation."),
    ],
    "Scorpion Sting": [
        ("Lidocaine", "5% topical", "Topical", "For local pain relief."),
        ("Acetaminophen", "500-1000 mg", "Oral", "For pain."),
    ],
    "Sunburn": [
        ("Ibuprofen", "400 mg", "Oral", "For pain and inflammation."),
        ("Aloe vera gel", "Apply liberally", "Topical", "Cooling and soothing."),
    ],
}


# ═══════════════════════════════════════════════════════════════════════
#  BUILD
# ═══════════════════════════════════════════════════════════════════════

def build():
    DB_DIR.mkdir(parents=True, exist_ok=True)
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(str(DB_PATH))
    cur = conn.cursor()
    cur.executescript(SCHEMA)

    # ── Insert conditions ──
    cond_ids = {}
    for name, triage, body_system, summary in CONDITIONS:
        cur.execute(
            "INSERT INTO conditions (name, triage, body_system, summary) VALUES (?,?,?,?)",
            (name, triage, body_system, summary),
        )
        cond_ids[name] = cur.lastrowid

    # ── Insert symptoms ──
    for cond_name, syms in SYMPTOMS.items():
        cid = cond_ids.get(cond_name)
        if cid is None:
            print(f"  WARNING: No condition found for symptom set '{cond_name}'")
            continue
        for symptom, weight in syms:
            cur.execute(
                "INSERT INTO condition_symptoms (condition_id, symptom, weight) VALUES (?,?,?)",
                (cid, symptom, weight),
            )

    # ── Insert phrases ──
    phrase_count = 0
    for cond_name, phr_list in PHRASES.items():
        cid = cond_ids.get(cond_name)
        if cid is None:
            # Try matching "Burns (general)" to first burn condition
            if "burn" in cond_name.lower():
                for bn in ["Minor Burns (1st Degree)", "Partial Thickness Burn", "Severe Burns (>20% BSA)"]:
                    if bn in cond_ids:
                        cid = cond_ids[bn]
                        break
            if cid is None:
                print(f"  WARNING: No condition found for phrase set '{cond_name}'")
                continue
        for phrase, canonical in phr_list:
            cur.execute(
                "INSERT INTO phrases (condition_id, phrase, canonical) VALUES (?,?,?)",
                (cid, phrase.lower(), canonical),
            )
            phrase_count += 1

    # ── Insert decision trees ──
    tree_count = 0
    for cond_name, cid in cond_ids.items():
        if cond_name in DECISION_TREES:
            tree = DECISION_TREES[cond_name]
        else:
            # Generate default tree from condition data
            triage = [c[1] for c in CONDITIONS if c[0] == cond_name][0]
            summary = [c[3] for c in CONDITIONS if c[0] == cond_name][0]
            tree = _default_tree(cond_name, summary, triage)
        cur.execute(
            "INSERT INTO decision_trees (condition_id, tree_json) VALUES (?,?)",
            (cid, json.dumps(tree)),
        )
        tree_count += 1

    # ── Insert protocols ──
    proto_count = 0
    for cond_name, steps in PROTOCOLS.items():
        cid = cond_ids.get(cond_name)
        if cid is None:
            print(f"  WARNING: No condition found for protocol '{cond_name}'")
            continue
        for i, (title, detail, warning) in enumerate(steps, 1):
            cur.execute(
                "INSERT INTO protocols (condition_id, step_order, title, detail, warning) VALUES (?,?,?,?,?)",
                (cid, i, title, detail, warning),
            )
            proto_count += 1

    # ── Insert medications ──
    med_count = 0
    for cond_name, meds in MEDICATIONS.items():
        cid = cond_ids.get(cond_name)
        if cid is None:
            continue
        for med_name, dose, route, notes in meds:
            cur.execute(
                "INSERT INTO medications (condition_id, name, dose, route, notes) VALUES (?,?,?,?,?)",
                (cid, med_name, dose, route, notes),
            )
            med_count += 1

    conn.commit()

    # ── Summary ──
    cur.execute("SELECT COUNT(*) FROM conditions")
    total_cond = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM condition_symptoms")
    total_sym = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM phrases")
    total_phr = cur.fetchone()[0]

    conn.close()
    size_kb = DB_PATH.stat().st_size / 1024

    print(f"\n✅  medical.db built → {DB_PATH}")
    print(f"    Conditions:       {total_cond}")
    print(f"    Symptom mappings: {total_sym}")
    print(f"    Phrases:          {total_phr}")
    print(f"    Decision trees:   {tree_count}")
    print(f"    Protocol steps:   {proto_count}")
    print(f"    Medications:      {med_count}")
    print(f"    Size:             {size_kb:.1f} KB\n")


if __name__ == "__main__":
    build()
