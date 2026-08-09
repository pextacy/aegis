import type { SVGProps } from "react";

/**
 * The icon set, drawn inline.
 *
 * The design calls for Material Symbols, which is a webfont served from a CDN.
 * Inlining the dozen glyphs this dashboard actually uses keeps the page free of
 * third-party requests — a treasury console that phones out to a font host on
 * every load is leaking which addresses are being looked at and when.
 */

type IconProps = SVGProps<SVGSVGElement>;

function Icon({ children, ...props }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.75}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...props}
    >
      {children}
    </svg>
  );
}

export function IconTreasury(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M3 9.5 12 4l9 5.5" />
      <path d="M5 10v8M9.5 10v8M14.5 10v8M19 10v8" />
      <path d="M3 20h18" />
    </Icon>
  );
}

export function IconPolicy(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M12 3.5 5 6v6c0 4.2 2.9 7.5 7 8.5 4.1-1 7-4.3 7-8.5V6l-7-2.5Z" />
      <circle cx="12" cy="11" r="2.2" />
      <path d="M12 13.2V16" />
    </Icon>
  );
}

export function IconAudit(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M3.5 12a8.5 8.5 0 1 0 2.6-6.1" />
      <path d="M3.5 4.5V9H8" />
      <path d="M12 8v4.4l3 1.8" />
    </Icon>
  );
}

export function IconPlus(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M12 5v14M5 12h14" />
    </Icon>
  );
}

export function IconArrowLeft(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M19 12H5M11 6l-6 6 6 6" />
    </Icon>
  );
}

export function IconArrowRight(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M5 12h14M13 6l6 6-6 6" />
    </Icon>
  );
}

export function IconChevronRight(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M9 5l7 7-7 7" />
    </Icon>
  );
}

export function IconCheck(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="m8.5 12 2.5 2.5 4.5-5" />
    </Icon>
  );
}

export function IconCross(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="m9.5 9.5 5 5M14.5 9.5l-5 5" />
    </Icon>
  );
}

export function IconPending(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M8.5 12h.01M12 12h.01M15.5 12h.01" />
    </Icon>
  );
}

export function IconLock(props: IconProps) {
  return (
    <Icon {...props}>
      <rect x="4.5" y="10.5" width="15" height="9.5" rx="2" />
      <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" />
    </Icon>
  );
}

export function IconShield(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M12 3.5 5 6v6c0 4.2 2.9 7.5 7 8.5 4.1-1 7-4.3 7-8.5V6l-7-2.5Z" />
    </Icon>
  );
}

export function IconCopy(props: IconProps) {
  return (
    <Icon {...props}>
      <rect x="9" y="9" width="11" height="11" rx="2" />
      <path d="M15 6.5A2.5 2.5 0 0 0 12.5 4H6.5A2.5 2.5 0 0 0 4 6.5v6A2.5 2.5 0 0 0 6.5 15" />
    </Icon>
  );
}

export function IconExternal(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M14 4h6v6" />
      <path d="M20 4 11 13" />
      <path d="M18 14v4.5A1.5 1.5 0 0 1 16.5 20h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10" />
    </Icon>
  );
}

export function IconSearch(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="11" cy="11" r="6.5" />
      <path d="m16 16 4 4" />
    </Icon>
  );
}

export function IconAlert(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M12 4.5 3 19.5h18L12 4.5Z" />
      <path d="M12 10v4M12 17h.01" />
    </Icon>
  );
}

export function IconFreeze(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M12 3v18M4.2 7.5l15.6 9M19.8 7.5l-15.6 9" />
      <path d="M9.5 5 12 7.5 14.5 5M9.5 19 12 16.5l2.5 2.5" />
    </Icon>
  );
}

export function IconLayers(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="m12 3.5 8.5 4.5L12 12.5 3.5 8Z" />
      <path d="m3.5 12.5 8.5 4.5 8.5-4.5" />
      <path d="m3.5 16.5 8.5 4.5 8.5-4.5" />
    </Icon>
  );
}

export function IconUsers(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="9.5" cy="8.5" r="3" />
      <path d="M3.5 19.5c0-3 2.7-5 6-5s6 2 6 5" />
      <path d="M16 6.2a3 3 0 0 1 0 5.6M17.5 14.9c1.9.6 3.2 2.3 3.2 4.6" />
    </Icon>
  );
}

export function IconClock(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5v4.8l3 1.8" />
    </Icon>
  );
}

export function IconWallet(props: IconProps) {
  return (
    <Icon {...props}>
      <rect x="3.5" y="6" width="17" height="12.5" rx="2.5" />
      <path d="M3.5 10h17" />
      <path d="M16.5 14.2h.01" />
    </Icon>
  );
}

export function IconKey(props: IconProps) {
  return (
    <Icon {...props}>
      <circle cx="8" cy="13" r="4" />
      <path d="m11 11 8-8 2 2-2 2 2 2-2 2-2-2-2 2-2-2" />
    </Icon>
  );
}

export function IconTrash(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M4.5 7h15" />
      <path d="M9.5 7V5.5A1.5 1.5 0 0 1 11 4h2a1.5 1.5 0 0 1 1.5 1.5V7" />
      <path d="M6.5 7v11.5A1.5 1.5 0 0 0 8 20h8a1.5 1.5 0 0 0 1.5-1.5V7" />
      <path d="M10.5 11v5M13.5 11v5" />
    </Icon>
  );
}

export function IconSend(props: IconProps) {
  return (
    <Icon {...props}>
      <path d="M20.5 3.5 3.5 10l7 3 3 7 7-16.5Z" />
      <path d="m10.5 13 4-4" />
    </Icon>
  );
}
