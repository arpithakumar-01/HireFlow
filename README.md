import os
import uuid
import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from backend.config import RESUMES_DIR, STATIC_DIR
from backend.storage import (
    load_db, get_all_roles, get_role_by_id, upsert_role, delete_role,
    get_candidates_by_role, get_candidate_by_id, upsert_candidate, delete_candidate,
    get_interview, upsert_interview, record_audit, load_settings, save_settings
)
from backend.parsers.jd_parser import parse_job_description
from backend.parsers.resume_parser import extract_text_from_file, parse_resume
from backend.intelligence.hybrid_ai import (
    process_candidate_screening, generate_follow_up_questions,
    evaluate_interview_record, execute_candidate_query
)
from backend.seed_data import seed_demo_data

app = FastAPI(title="HireFlow API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Pydantic Schemas
class CreateRoleRequest(BaseModel):
    title: str
    department: Optional[str] = "Engineering"
    min_experience_years: Optional[int] = 3
    description: str

class SettingsRequest(BaseModel):
    gemini_api_key: Optional[str] = ""
    model_name: Optional[str] = "gemini-3.8-flash"
    mode: Optional[str] = "auto" # auto, gemini_only, nlp_only

class FollowUpRequest(BaseModel):
    question: str
    candidate_answer: str
    focus_area: Optional[str] = "depth"

class SaveInterviewRequest(BaseModel):
    notes: str
    answers: Optional[Dict[str, str]] = {}
    follow_ups: Optional[List[Dict[str, str]]] = []

class EvaluateInterviewRequest(BaseModel):
    notes: str

class NLQueryRequest(BaseModel):
    query: str

# API Routes
@app.get("/api/health")
def health_check():
    return {"status": "ok", "service": "HireFlow AI Agent", "timestamp": datetime.datetime.now().isoformat()}

@app.get("/api/settings")
def get_current_settings():
    settings = load_settings()
    masked_key = ""
    if settings.get("gemini_api_key"):
        raw_key = settings["gemini_api_key"]
        masked_key = raw_key[:4] + "..." + raw_key[-4:] if len(raw_key) > 8 else "***"
    return {
        "has_api_key": bool(settings.get("gemini_api_key")),
        "masked_api_key": masked_key,
        "model_name": settings.get("model_name", "gemini-3.8-flash"),
        "mode": settings.get("mode", "auto")
    }

@app.post("/api/settings")
def update_settings(req: SettingsRequest):
    current = load_settings()
    if req.gemini_api_key is not None and req.gemini_api_key != "":
        current["gemini_api_key"] = req.gemini_api_key.strip()
    if req.model_name:
        current["model_name"] = req.model_name
    if req.mode:
        current["mode"] = req.mode
    save_settings(current)
    return {"status": "success", "message": "Settings updated successfully"}

@app.post("/api/seed-demo")
def trigger_seed_demo():
    res = seed_demo_data()
    return res

@app.get("/api/roles")
def list_roles():
    roles = get_all_roles()
    result = []
    for r in roles:
        candidates = get_candidates_by_role(r["id"])
        avg_score = 0.0
        if candidates:
            avg_score = round(sum(c.get("match_score", 0) for c in candidates) / len(candidates), 1)
        tier_counts = {
            "Tier 1: Strong Match": 0,
            "Tier 2: Strong Contender": 0,
            "Tier 3: Potential Fit": 0,
            "Tier 4: Substantial Gap": 0
        }
        for c in candidates:
            t = c.get("tier", "Tier 3: Potential Fit")
            tier_counts[t] = tier_counts.get(t, 0) + 1

        result.append({
            **r,
            "candidate_count": len(candidates),
            "average_match_score": avg_score,
            "tier_counts": tier_counts
        })
    return result

@app.post("/api/roles")
def create_role(req: CreateRoleRequest):
    role_id = f"role-{uuid.uuid4().hex[:8]}"
    parsed = parse_job_description(
        req.description,
        title=req.title,
        department=req.department,
        min_exp=req.min_experience_years
    )
    role_obj = {
        "id": role_id,
        "title": parsed["title"],
        "department": parsed["department"],
        "min_experience_years": parsed["min_experience_years"],
        "detected_skills": parsed["detected_skills"],
        "requirements": parsed["requirements"],
        "responsibilities": parsed["responsibilities"],
        "raw_text": req.description,
        "created_at": datetime.datetime.now().isoformat()
    }
    upsert_role(role_obj)
    record_audit("ROLE_CREATED", role_id, {"title": role_obj["title"], "req_count": len(role_obj["requirements"])})
    return role_obj

@app.get("/api/roles/{role_id}")
def get_role(role_id: str):
    role = get_role_by_id(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="Role not found")
    return role

@app.delete("/api/roles/{role_id}")
def delete_role_endpoint(role_id: str):
    success = delete_role(role_id)
    if not success:
        raise HTTPException(status_code=404, detail="Role not found")
    record_audit("ROLE_DELETED", role_id, {})
    return {"status": "success", "message": "Role and associated candidates removed"}

@app.post("/api/roles/{role_id}/upload-resumes")
async def upload_resumes(role_id: str, files: List[UploadFile] = File(...)):
    role = get_role_by_id(role_id)
    if not role:
        raise HTTPException(status_code=404, detail="Role not found")

    uploaded_candidates = []
    for file in files:
        file_ext = Path(file.filename).suffix.lower()
        if file_ext not in [".pdf", ".docx", ".doc", ".txt", ".md"]:
            continue

        cand_id = f"cand-{uuid.uuid4().hex[:8]}"
        save_path = RESUMES_DIR / f"{cand_id}_{file.filename}"
        content = await file.read()
        with open(save_path, "wb") as f:
            f.write(content)

        raw_text = extract_text_from_file(str(save_path))
        cand_parsed = parse_resume(raw_text, filename=file.filename)
        cand_parsed["id"] = cand_id
        cand_parsed["role_id"] = role_id
        cand_parsed["filename"] = file.filename
        cand_parsed["uploaded_at"] = datetime.datetime.now().isoformat()

        # Execute AI screening against current role requirements
        screening_res = process_candidate_screening(cand_parsed, role)
        cand_parsed.update(screening_res)

        upsert_candidate(cand_parsed)
        record_audit("CANDIDATE_UPLOADED_AND_SCREENED", cand_id, {
            "role_id": role_id,
            "filename": file.filename,
            "match_score": screening_res["match_score"],
            "tier": screening_res["tier"]
        })
        uploaded_candidates.append({
            "id": cand_id,
            "name": cand_parsed["name"],
            "filename": file.filename,
            "match_score": cand_parsed["match_score"],
            "tier": cand_parsed["tier"]
        })

    return {
        "status": "success",
        "uploaded_count": len(uploaded_candidates),
        "candidates": uploaded_candidates
    }

@app.get("/api/roles/{role_id}/candidates")
def list_role_candidates(role_id: str):
    candidates = get_candidates_by_role(role_id)
    return candidates

@app.get("/api/candidates/{candidate_id}")
def get_candidate_details(candidate_id: str):
    cand = get_candidate_by_id(candidate_id)
    if not cand:
        raise HTTPException(status_code=404, detail="Candidate not found")
    return cand

@app.delete("/api/candidates/{candidate_id}")
def delete_candidate_endpoint(candidate_id: str):
    success = delete_candidate(candidate_id)
    if not success:
        raise HTTPException(status_code=404, detail="Candidate not found")
    record_audit("CANDIDATE_DELETED", candidate_id, {})
    return {"status": "success", "message": "Candidate removed"}

@app.get("/api/candidates/{candidate_id}/interview")
def get_candidate_interview(candidate_id: str):
    interview = get_interview(candidate_id)
    if not interview:
        return {"candidate_id": candidate_id, "notes": "", "answers": {}, "follow_ups": []}
    return interview

@app.post("/api/candidates/{candidate_id}/interview")
def save_candidate_interview(candidate_id: str, req: SaveInterviewRequest):
    cand = get_candidate_by_id(candidate_id)
    if not cand:
        raise HTTPException(status_code=404, detail="Candidate not found")
    
    interview_data = {
        "candidate_id": candidate_id,
        "role_id": cand.get("role_id"),
        "notes": req.notes,
        "answers": req.answers or {},
        "follow_ups": req.follow_ups or [],
        "updated_at": datetime.datetime.now().isoformat()
    }
    upsert_interview(interview_data)
    record_audit("INTERVIEW_NOTES_SAVED", candidate_id, {"notes_length": len(req.notes)})
    return {"status": "success", "message": "Interview data recorded"}

@app.post("/api/candidates/{candidate_id}/follow-up")
def request_follow_up(candidate_id: str, req: FollowUpRequest):
    cand = get_candidate_by_id(candidate_id)
    if not cand:
        raise HTTPException(status_code=404, detail="Candidate not found")
    
    follow_ups = generate_follow_up_questions(
        req.question, req.candidate_answer, req.focus_area or "depth"
    )
    record_audit("FOLLOW_UP_GENERATED", candidate_id, {
        "question": req.question[:60],
        "generated_count": len(follow_ups)
    })
    return {"status": "success", "follow_ups": follow_ups}

@app.post("/api/candidates/{candidate_id}/evaluate")
def evaluate_interview(candidate_id: str, req: EvaluateInterviewRequest):
    cand = get_candidate_by_id(candidate_id)
    if not cand:
        raise HTTPException(status_code=404, detail="Candidate not found")
    role = get_role_by_id(cand.get("role_id", ""))
    if not role:
        raise HTTPException(status_code=404, detail="Role not found")

    evaluation_report = evaluate_interview_record(req.notes, role, cand)
    record_audit("INTERVIEW_EVALUATED", candidate_id, {
        "recommendation": evaluation_report.get("recommendation"),
        "overall_score": evaluation_report.get("overall_score")
    })
    return evaluation_report

@app.post("/api/roles/{role_id}/query")
def natural_language_query(role_id: str, req: NLQueryRequest):
    candidates = get_candidates_by_role(role_id)
    if not candidates:
        return {"query": req.query, "results": []}
    results = execute_candidate_query(req.query, candidates)
    record_audit("NATURAL_LANGUAGE_QUERY", role_id, {
        "query": req.query,
        "matched_candidates": len(results)
    })
    return {"query": req.query, "results": results}

@app.get("/api/audit-trail")
def get_audit_trail(limit: int = 50):
    db = load_db()
    logs = db.get("audit_logs", [])
    return logs[-limit:][::-1]

# Mount Frontend Static Files
if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="frontend")

