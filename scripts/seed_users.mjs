import { createClient } from "@supabase/supabase-js";
import crypto from "crypto";

const emails = [
  // Screenshot 1
  "efosaatujohnon@gmail.com","rayburnkhalz@gmail.com","chinemeremfavour2023@gmail.com",
  "ayclassicpro@gmail.com","damilarejaiyeoba4@gmail.com","daddy1yo2@gmail.com",
  "fawazagbeniyi4@gmail.com","kiser9021@gmail.com","boasiwaju@gmail.com",
  "kellyjameskj0@gmail.com","stacey4000f@gmail.com","lyrician30d@gmail.com",
  "yungupdate419@gmail.com","flexnikki54@gmail.com","samueloluwapelumi901@gmail.com",
  "kendalll.trucking89@gmail.com","hamzatadetunji4@gmail.com","sarahsmi100@gmail.com",
  // Screenshot 2
  "emmanuelolowookere959@gmail.com","bigbayorvu123@gmail.com","copperkevin121@gmail.com",
  "beautymistress27@gmail.com","adexliade@gmail.com","schoolboyyy0@gmail.com",
  "maverickrp521@gmail.com","shagyman47@gmail.com","asomahjames86@gmail.com",
  "pappiechi047@gmail.com","adamayobami081@gmail.com","bidfind31@gmail.com",
  // Screenshot 3
  "dagoldsmithval@gmail.com","adeyemiadeife83@gmail.com","princejehu12345@gmail.com",
  "asomahy05@gmail.com","nimasjunior11@gmail.com","ojediransodiq86@gmail.com",
  "anjeremy7017@gmail.com","paulamber054@gmail.com","worldpresidentowoniboyz@gmail.com",
  "ayomideayinuola87@gmail.com","promisejames545@gmail.com","sopyjaja16@gmail.com",
  "dfwpain286@gmail.com","ohkyes11@gmail.com","yunggee190@gmail.com",
  "lomitashootersleague@gmail.com",
];

const unique = [...new Set(emails.map((e) => e.toLowerCase().trim()))];
console.log(`Seeding ${unique.length} users...`);

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

let created = 0, existed = 0, failed = 0;
for (const email of unique) {
  const tempPw = crypto.randomBytes(24).toString("base64url");
  const { data, error } = await sb.auth.admin.createUser({
    email,
    password: tempPw,
    email_confirm: true,
  });
  if (error) {
    if (/already|registered|exists/i.test(error.message)) { existed++; console.log(`= ${email} (exists)`); }
    else { failed++; console.log(`✗ ${email}: ${error.message}`); }
  } else {
    created++; console.log(`+ ${email} -> ${data.user.id}`);
  }
}
console.log(`\nDone. created=${created} existed=${existed} failed=${failed}`);
