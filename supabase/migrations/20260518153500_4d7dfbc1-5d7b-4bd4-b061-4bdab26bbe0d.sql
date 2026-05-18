UPDATE public.app_settings SET
  terms_content = $txt$LOMITA SHOOTERS LEAGUE – Terms and Conditions
Effective Date: May 7, 2026
By registering an account or using LOMITA SHOOTERS LEAGUE, you agree to be bound by these Terms and Conditions.


ACCOUNT CREATION
Users must be 18 years or older to create an account. During registration, you are required to provide accurate personal and in-game information, including your preferred full name, email, phone number (optional), Discord username, country, server, gang/faction name, and password.

Only one account per person is permitted. 
Creating multiple accounts is strictly prohibited and will result in immediate suspension or permanent ban of all accounts.

ACCOUNT MANAGEMENT
You are fully responsible for all activities conducted under your account. You must keep your login credentials secure. 
The platform reserves the right to suspend, restrict, or terminate any account at its sole discretion for violations of these Terms. 
You can manage and update your profile information through the user dashboard. 

BETTING
Placing Bets
All bets placed are final once confirmed and tokens are deducted from your balance. You may edit your bet slip (add, remove selections, change stake, or reorder) only before final confirmation. Duplicate bets on the same match and market are not allowed. 
All betting is done with virtual tokens for entertainment purposes only. 

MAXIMUM PAYOUT
The maximum possible payout or cashout on any bet (single or accumulator) is 60,000,000 tokens. This limit is strictly enforced regardless of stake or odds.

NO REFUND POLICY
Once a bet is confirmed, no refunds will be issued for lost or settled bets. Refunds are only possible if a match is officially voided or cancelled by the Admin team. There are no refunds after a match has started or been finalized.

TOKENSTOKEN REQUESTS
Users can request virtual tokens through the platform's token request system. Each request may require supporting evidence (such as image upload). All token requests are subject to review and approval by the Admin team. The platform reserves the right to approve or deny any request without prior notice. 

PROMO CODES
Administrators may issue promo codes for free tokens. Promo codes are subject to usage limits, expiry dates, and terms specified at the time of issuance. Abuse, sharing, or fraudulent use of promo codes may result in account suspension and forfeiture of tokens.

CHATTEXTING CONDUCT
Users must maintain respectful, appropriate, and lawful behavior in all chat rooms (General Chat, Gang Chat, and Moderator Chat). Harassment, hate speech, spam, threats, bullying, or sharing of illegal, offensive, or inappropriate content is strictly prohibited. Violations may result in temporary or permanent mute from chat rooms and/or account suspension.

SECURITY
Suspicious Activity
Any form of suspicious, fraudulent, exploitative, or manipulative behavior (including but not limited to multi-accounting, betting exploitation, system abuse, or attempting to manipulate matches/odds) is strictly forbidden. The platform will investigate all suspected violations and may suspend accounts and freeze tokens during investigation.

LOGIN TRACKING
The platform logs login activities for security and fraud prevention. Unusual login patterns (multiple devices, different locations, etc.) may trigger additional verification or temporary account restrictions. You are responsible for all activities that occur under your account.

GENERAL ACCEPTANCE
By creating an account and using LOMITA SHOOTERS LEAGUE, you confirm that you have read, understood, and voluntarily agreed to these Terms and Conditions in their entirety. Continued use of the platform after any updates constitutes acceptance of the revised Terms.

Contact Us
For any questions or concerns, please reach out to us at:
Email: lomitashootersleague@gmail.com
By using this platform, you acknowledge and accept these Terms and Conditions.
$txt$,
  about_us = $txt$ABOUT US

Welcome to the ultimate exchange and betting arena for the RPG ecosystem. We provide a high-performance bridge between your in-game wealth and high-stakes rewards, allowing you to put your hard-earned currency to work.

THE CYCLE OF PLAY
 DEPOSIT: Convert your in-game currency into platform **Tokens** instantly.
 WAGER: Use your Tokens to place bets on a fast, reliable, and secure interface.
 WITHDRAWAL: Convert your winnings back into in-game currency and cash out to your character with zero friction$txt$,
  why_trust_us = $txt$WHY US?
SPEED: No middle-men. No delays. Our automated system ensures your assets move as fast as you do.

RELIABILITY: Engineered with mechanical precision to ensure every bet and every conversion is handled accurately.

SECURITY: Your gaming assets are protected by industry-leading encryption and a transparent ledger.
Grind the game. Win the arena. Rule the server.
$txt$,
  contact_phone = $txt$+234$txt$,
  contact_whatsapp = $txt$+234$txt$,
  hero_tagline = $txt$SEASON 2 TOURNAMENT • COMING SOON $txt$,
  min_stake = 2000000,
  max_payout = 60000000,
  min_withdrawal = 2000000,
  daily_login_base_reward = 200,
  daily_login_bonus_per_day = 0.1,
  daily_login_max_streak = 30,
  xp_per_bet = 50,
  xp_per_win = 65,
  xp_per_login = 20,
  xp_per_referral = 100,
  referral_bonus_referrer = 500000,
  referral_bonus_referee = 250000,
  vip_token_multipliers = $json${"bronze":1,"gold":1.1,"legend":1.5,"platinum":1.25,"silver":1.05}$json$::jsonb,
  challenge_reward_multiplier = 1,
  spin_enabled = true,
  spin_min_reward = 50000,
  spin_max_reward = 150000,
  spin_cooldown_hours = 24,
  gift_enabled = false,
  gift_daily_limit = 5,
  gift_min_amount = 100000,
  gift_max_per_tx = 5000000,
  gift_fee_pct = 0,
  friends_enabled = true,
  admin_ai_enabled = true,
  admin_ai_model = $txt$google/gemini-2.5-flash$txt$,
  exposure_warn_pct = 70,
  house_low_balance = 1000000,
  min_selections_per_ticket = 1,
  max_selections_per_ticket = 20,
  emblem_auto_approve = false,
  vip_enabled = true,
  virtual_payout_multiplier = 1.0,
  virtual_min_stake = 100000,
  virtual_max_stake = 10000000,
  virtual_xp_per_win = 15,
  virtual_win_bonus_tokens = 0,
  daily_login_enabled = true,
  updated_at = now()
WHERE id = 1;

UPDATE public.house_wallet
SET balance = 11906755,
    total_in = 529850496,
    total_out = 517943741,
    payouts_paused = false,
    pause_reason = NULL,
    updated_at = now()
WHERE id = 1;