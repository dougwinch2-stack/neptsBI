# neptsBI – setup (step 1: MOT)

Uses the same Supabase project as the parking app, in its own separate area ("neptsbi"),
so the parking app isn't touched. About 10 minutes.

## 1. Load the database (Supabase → SQL Editor)
Run these files **in order**: open each one, copy everything, paste it into
**SQL Editor → New query**, then click **Run**.

1. `sql/01_schema.sql`: creates the tables
2. `sql/02_demo_data.sql`: the demo vans, MOT history and people
3. `sql/03_nightly_reset.sql`: the 2:30am reset
4. `sql/04_mileage.sql`: daily mileage (two years)
5. `sql/05_servicing.sql`: services and service bookings
6. `sql/06_work.sql`: results waiting to be logged
7. `sql/07_vor.sql`: the VOR (vehicle off road) rule
8. `sql/08_equipment.sql`: fire extinguishers, defibs and the demo story switch
9. `sql/09_cleans_oxygen.sql`: deep cleans and oxygen cylinders
10. `sql/10_equipment_actions.sql`: log a clean, swap a cylinder, log an extinguisher or defib check
11. `sql/11_demos.sql`: the numbered demos (⋮ › Demo)
12. `sql/12_clean_rota.sql`: the deep clean contractor's rota (a few days at each base in turn)

Each should say "Success. No rows returned" (03 shows a number, which is fine).
Files 08–12 are safe to run again.

## 2. Switch the new area on for the app (one-off)
Supabase → **Project Settings** → **Data API**. Under **Exposed schemas**, add
**neptsbi** to the list (keep `public` there for the parking app), then **Save**.

If you skip this, the app shows: "The database isn't switched on for the app yet".

## 3. Put the app on GitHub
1. GitHub → **New repository** → name **neptsBI** → Public → Create.
2. **Add file → Upload files**. Drag in everything from the `site` folder:
   `index.html`, `app.html`, `neptsbi.js`, `neptsbi.css`, `dougs.css`, `dougs.js`.
   (You can also upload the `sql` and `tools` folders and this file, to keep them safe.)
3. Commit.
4. **Settings → Pages** → Branch **main**, folder **/ (root)** → Save.

After a minute it's live at **https://dougwinch2-stack.github.io/neptsBI/**

No keep-alive is needed: the parking app's keep-alive already keeps this Supabase project awake.

---

## Demo links (bookmark these, or turn them into QR codes)
| Who | Link |
|---|---|
| Sign-in page | `…/neptsBI/` |
| Chief Executive | `…/neptsBI/app.html?as=ceo` |
| Head of Delivery | `…/neptsBI/app.html?as=delivery` |
| Regional Manager – Essex | `…/neptsBI/app.html?as=region-essex` |
| Canvey Base Manager | `…/neptsBI/app.html?as=base-canvey` |
| Fleet Administrator | `…/neptsBI/app.html?as=admin` |
| Driver 001 (Canvey) | `…/neptsBI/app.html?as=driver-001` |

## The demo story (same every day)
- **320 vehicles**: Canvey 100, Chelmsford 66, Southend 34 (real numbers), plus made-up Region X and Region Y.
- **3 vans off the road with an overdue MOT, 1 more in Region X:**
  - **AMB017**, Canvey: 6 days overdue, booked for tomorrow ("priority slot")
  - **AMB058**, Canvey: 2 days overdue, **not booked** (the one to act on)
  - **AMB183**, Southend: 11 days overdue, booked, awaiting parts
  - **AMB224**, Base X1: its first MOT is overdue, booked
- About 14 vans are due in the next 30 days, and some aren't booked yet.

**A good run-through:** sign in as the CEO (98.8% compliant), tap the red number, open AMB017,
then switch to the Canvey Base Manager and record AMB017's MOT as a pass. Switch back to the
CEO: the overdue count has dropped and compliance has gone up.

## Resetting
- **Every night at 2:30am** anything added during demos is wiped and the dates move forward,
  so it's always "today" and the same story.
- **Between demos on the same day:** ⋮ menu → **Reset demo**.
- If the nightly job ever misses, the dates still move forward on the first visit of the day.

## Changing the demo data
Edit `tools/make_demo_data.py`, run it (it rewrites `sql/02_demo_data.sql`), then reload.
Ask Claude to do it.
