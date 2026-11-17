# Streako – Einrichtung (ca. 15 Minuten)

Du brauchst: die Dateien `index.html`, `apple-touch-icon.png` und `schema.sql`, einen Laptop/PC und beide iPhones.

## 1. Supabase-Projekt anlegen (Datenbank + Fotos)
1. Auf **supabase.com** einen kostenlosen Account anlegen (das machst du selbst).
2. **New project**: Name `streako`, Region **Frankfurt (eu-central-1)**, ein starkes Datenbank-Passwort vergeben und gut aufheben.
3. Warten, bis das Projekt fertig ist (1–2 Minuten).

## 2. Datenbank-Vorlage einspielen
1. Links **SQL Editor** → **New query**.
2. Den kompletten Inhalt von `schema.sql` reinkopieren → **Run**.
3. Supabase warnt eventuell vor einer „destructive operation“ – das ist normal (die Vorlage räumt alte Regeln weg), einfach bestätigen.
4. Es sollte „Success“ kommen. Mehrmaliges Ausführen schadet nicht – auch nicht, wenn du später eine neue Version der Vorlage einspielst.

## 3. Schlüssel in die App eintragen
1. Oben auf **Connect** klicken oder **Project Settings → API Keys** öffnen.
2. Die **Project URL** kopieren (`https://xxxx.supabase.co`).
3. Den **Publishable key** kopieren (beginnt mit `sb_publishable_…`). Falls dein Projekt nur den alten **anon public**-Key zeigt (beginnt mit `eyJ…`), nimm den.
4. `index.html` in einem Texteditor öffnen und ganz oben im Script eintragen:
   ```js
   const SUPABASE_URL = 'https://xxxx.supabase.co';
   const SUPABASE_ANON_KEY = 'sb_publishable_...';
   ```
   Dieser Key darf öffentlich sein – geschützt wird alles über die Regeln in der Datenbank.
   **Niemals** den **Secret key** (`sb_secret_…`) oder den alten **service_role**-Key eintragen.

## 4. App kostenlos online stellen (GitHub Pages)
1. Auf **github.com** ein neues Repository `streako` anlegen (Public).
2. **Add file → Upload files** → `index.html` und `apple-touch-icon.png` hochladen → Commit.
3. **Settings → Pages** → Source: „Deploy from a branch“, Branch `main`, Ordner `/ (root)` → Save.
4. Nach 1–2 Minuten läuft die App unter `https://DEINNAME.github.io/streako/`.

## 5. E-Mail-Bestätigung ausschalten (wichtig!)
Der Gratis-Mailversand von Supabase schickt Bestätigungs-Mails nur an Mitglieder deines Supabase-Teams – deine Schwester bekäme also keine Mail.
In Supabase: **Authentication → Sign In / Providers → Email** → **„Confirm email“ ausschalten** → Save.
Das ist unkritisch, weil du die Registrierung in Schritt 7 sowieso komplett zumachst.

Zusätzlich unter **Authentication → URL Configuration** bei **Site URL** deine GitHub-Pages-Adresse eintragen.

## 6. Auf beiden iPhones einrichten
1. Link in **Safari** öffnen → **Teilen → Zum Home-Bildschirm**.
2. Die App **vom Home-Bildschirm** öffnen (nicht in Safari weitermachen – die Home-Bildschirm-App hat ihren eigenen Login).
3. **Neu registrieren** (E-Mail + Passwort) → Namen eingeben.
4. Beim ersten Beweis **Kamera** und **Standort** erlauben.

Es können nur **2 Spieler** beitreten. Wer sich sonst registriert, sieht nichts.

## 7. Danach dichtmachen
Wenn ihr beide drin seid: **Authentication → Sign In / Providers** (bzw. Settings) → **„Allow new users to sign up“ ausschalten**.

## So funktioniert's
- **Challenges** legst du im Profil an (jeden Tag, bestimmte Wochentage, ein Datum oder alle X Tage, z. B. 14 = alle 2 Wochen), optional mit Uhrzeit. Die andere Person muss sie bestätigen. Punkte ändern = Challenge beenden und neu anlegen.
- **Beweis**: nur Live-Kamera, die Uhrzeit setzt der Server, die genaue Position wird gespeichert (erst ab ±150 m Genauigkeit). Hat die Challenge eine Uhrzeit, steht beim Prüfen „pünktlich“ oder „zu spät“. Pro Challenge und Tag ein Beweis (nach Ablehnung nochmal möglich). Nach Mitternacht zählt der neue Tag.
- **Prüfen**: im Duell-Tab bestätigt ihr gegenseitig Beweise, neue Challenges, Belohnungs-Preise und Pause-Tage.
- **Streak**: Tage am Stück, an denen alles erledigt war. Tage ohne Challenges und bestätigte Pause-Tage zählen nicht dagegen. **1 Joker pro Woche** rettet einen verpassten Tag automatisch. Pause-Tage gehen nur für heute oder später und zählen erst, wenn die andere Person zustimmt.
- **Shop**: eigene Belohnungen anlegen, die andere Person bestätigt den Preis. Nach dem Einlösen hakt sie „Erledigt“ ab.
- **Fotos** werden 3 Tage nach der Prüfung gelöscht (nie geprüfte nach 7 Tagen) – jeweils beim nächsten Öffnen der App. Zeit, Ort und Punkte bleiben.

## Gut zu wissen
- **Gratis-Grenzen** bei Supabase: 500 MB Datenbank, 1 GB Speicher – reicht locker, weil Fotos gelöscht werden. Ein Gratis-Projekt **pausiert nach ca. 7 Tagen ohne Nutzung**; dann im Supabase-Dashboard auf „Restore“ drücken.
- **Nicht 100 % fälschungssicher**: Ein Foto von einem anderen Bildschirm, gefälschtes GPS mit Spezial-Apps oder wer mit Programmier-Wissen direkt an der App vorbei Daten schickt – das geht theoretisch. Server-Zeit, frisches Foto (max. 10 Minuten alt, jedes Foto nur einmal), Ort und gegenseitiges Prüfen machen Schummeln aber richtig nervig.
- **Wer nicht prüft, blockiert Punkte** – also regelmäßig in den Duell-Tab schauen (roter Punkt am Pokal).
- **Erinnerungs-Push** ist noch nicht drin. Das wäre ein nächster Ausbauschritt.
- Name der App ändern: in `index.html` „Streako“ ersetzen.
