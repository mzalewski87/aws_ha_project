/**
 * Vector SVG Icons for Palo Alto Networks & AWS Components
 * Accurately styled with official brand colors.
 */

const ICONS = {
  // Palo Alto Networks Brand Fire & Logo
  "panw-logo": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B"/>
      <path d="M24 8C24 8 28.5 13.5 28.5 18C28.5 20.8 26.5 22.8 24 22.8C21.5 22.8 19.5 20.8 19.5 18C19.5 13.5 24 8 24 8Z" fill="#FA582D"/>
      <path d="M24 24C16.8 24 11 29.8 11 37C11 38.5 11.3 40 11.7 41.2C13.8 38.2 17.5 36.2 21.8 36.2C24.4 36.2 26.7 37 28.5 38.4C27.5 35.8 27 33 27 30C27 27.5 27.8 25.2 29.2 23.3C27.6 23.7 25.8 24 24 24Z" fill="#FA582D"/>
      <path d="M37 37C37 29.8 31.2 24 24 24C23.2 24 22.4 24.1 21.7 24.2C23.1 26.1 24 28.5 24 31C24 34.2 22.8 37.1 20.8 39.3C21.8 39.8 22.9 40 24 40C31.2 40 37 34.2 37 37Z" fill="#FF8364"/>
    </svg>
  `,

  // PAN-OS VM-Series Firewall
  "panw-vmseries": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#0F172A" stroke="#FA582D" stroke-width="2"/>
      <path d="M24 10L36 17V26C36 33.2 30.9 39.8 24 41.5C17.1 39.8 12 33.2 12 26V17L24 10Z" fill="#1E293B" stroke="#FA582D" stroke-width="2"/>
      <path d="M24 18C24 18 27 21 27 23.5C27 25.2 25.7 26.5 24 26.5C22.3 26.5 21 25.2 21 23.5C21 21 24 18 24 18Z" fill="#FA582D"/>
      <path d="M24 27C20 27 17 29.5 17 33C18.5 32 21 31.5 23.5 31.5C25.5 31.5 27 32 28.5 33C28.2 30.5 26.5 27 24 27Z" fill="#FA582D"/>
    </svg>
  `,

  // Panorama Central Management
  "panw-panorama": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#0F172A" stroke="#FF6B35" stroke-width="2"/>
      <rect x="12" y="12" width="24" height="24" rx="4" fill="#1E293B" stroke="#FF6B35" stroke-width="1.5"/>
      <circle cx="24" cy="24" r="5" fill="#FA582D"/>
      <circle cx="24" cy="24" r="9" stroke="#38BDF8" stroke-width="1.5" stroke-dasharray="3 3"/>
      <line x1="24" y1="12" x2="24" y2="15" stroke="#38BDF8" stroke-width="2"/>
      <line x1="24" y1="33" x2="24" y2="36" stroke="#38BDF8" stroke-width="2"/>
      <line x1="12" y1="24" x2="15" y2="24" stroke="#38BDF8" stroke-width="2"/>
      <line x1="33" y1="24" x2="36" y2="24" stroke="#38BDF8" stroke-width="2"/>
    </svg>
  `,

  // GlobalProtect Portal & Gateway
  "panw-globalprotect": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#0F172A" stroke="#00F0FF" stroke-width="2"/>
      <circle cx="24" cy="24" r="14" stroke="#00F0FF" stroke-width="2"/>
      <path d="M10 24H38" stroke="#00F0FF" stroke-width="1.5"/>
      <path d="M24 10C27.5 14 29.5 19 29.5 24C29.5 29 27.5 34 24 38C20.5 34 18.5 29 18.5 24C18.5 19 20.5 14 24 10Z" stroke="#00F0FF" stroke-width="1.5"/>
      <circle cx="24" cy="24" r="4" fill="#FA582D"/>
    </svg>
  `,

  // AWS Logo / Cloud
  "aws-logo": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#232F3E"/>
      <path d="M14 28C14 24.7 16.7 22 20 22C20.5 22 21 22.1 21.5 22.2C22.6 19.2 25.5 17 29 17C33.4 17 37 20.6 37 25C37 25.3 37 25.7 36.9 26C38.7 26.9 40 28.8 40 31C40 34.3 37.3 37 34 37H16C12.7 37 10 34.3 10 31C10 29.6 10.5 28.3 11.3 27.3C11.1 26.6 11 25.8 11 25C11 21.7 13.7 19 17 19" stroke="#FF9900" stroke-width="2"/>
    </svg>
  `,

  // AWS Global Accelerator
  "aws-global-accelerator": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#A855F7" stroke-width="2"/>
      <circle cx="24" cy="24" r="13" stroke="#A855F7" stroke-width="2"/>
      <path d="M16 28L28 16M28 16H20M28 16V24" stroke="#38BDF8" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="16" cy="28" r="3" fill="#FF9900"/>
    </svg>
  `,

  // AWS CloudFront
  "aws-cloudfront": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#A855F7" stroke-width="2"/>
      <circle cx="24" cy="24" r="13" stroke="#A855F7" stroke-width="2"/>
      <circle cx="24" cy="24" r="6" stroke="#38BDF8" stroke-width="1.5"/>
      <circle cx="15" cy="18" r="2" fill="#FF9900"/>
      <circle cx="33" cy="18" r="2" fill="#FF9900"/>
      <circle cx="24" cy="33" r="2" fill="#FF9900"/>
    </svg>
  `,

  // AWS Transit Gateway
  "aws-transit-gateway": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#FF9900" stroke-width="2"/>
      <circle cx="24" cy="24" r="6" fill="#FF9900"/>
      <path d="M24 10V18M24 30V38M10 24H18M30 24H38" stroke="#FF9900" stroke-width="2" stroke-linecap="round"/>
      <circle cx="24" cy="10" r="2.5" fill="#38BDF8"/>
      <circle cx="24" cy="38" r="2.5" fill="#38BDF8"/>
      <circle cx="10" cy="24" r="2.5" fill="#38BDF8"/>
      <circle cx="38" cy="24" r="2.5" fill="#38BDF8"/>
    </svg>
  `,

  // AWS TGW Peering
  "aws-transit-gateway-peering": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#38BDF8" stroke-width="2"/>
      <circle cx="16" cy="24" r="5" stroke="#FF9900" stroke-width="2"/>
      <circle cx="32" cy="24" r="5" stroke="#FF9900" stroke-width="2"/>
      <path d="M21 21L27 27M21 27L27 21" stroke="#38BDF8" stroke-width="2" stroke-linecap="round"/>
    </svg>
  `,

  // AWS VPC
  "aws-vpc": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#8B5CF6" stroke-width="1.5"/>
      <rect x="10" y="10" width="28" height="28" rx="4" stroke="#8B5CF6" stroke-width="1.5" stroke-dasharray="3 3"/>
      <circle cx="24" cy="24" r="4" fill="#8B5CF6"/>
    </svg>
  `,

  // AWS EC2
  "aws-ec2": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#FF9900" stroke-width="1.5"/>
      <rect x="13" y="13" width="22" height="22" rx="4" fill="#232F3E" stroke="#FF9900" stroke-width="1.5"/>
      <path d="M19 24H29M24 19V29" stroke="#FF9900" stroke-width="2"/>
    </svg>
  `,

  // AWS Directory Service / Active Directory
  "aws-directory-service": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#3B82F6" stroke-width="1.5"/>
      <rect x="12" y="12" width="24" height="24" rx="4" fill="#1E3A8A"/>
      <circle cx="24" cy="20" r="3.5" fill="#60A5FA"/>
      <path d="M17 31C17 27.7 20.1 25 24 25C27.9 25 31 27.7 31 31" stroke="#60A5FA" stroke-width="2"/>
    </svg>
  `,

  // AWS Systems Manager (SSM)
  "aws-ssm": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#10B981" stroke-width="1.5"/>
      <path d="M24 12L34 18V30L24 36L14 30V18L24 12Z" stroke="#10B981" stroke-width="2"/>
      <circle cx="24" cy="24" r="3" fill="#10B981"/>
    </svg>
  `,

  // Network Load Balancer (NLB)
  "aws-nlb": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <rect width="48" height="48" rx="10" fill="#1E293B" stroke="#8B5CF6" stroke-width="1.5"/>
      <rect x="14" y="14" width="20" height="20" rx="3" stroke="#8B5CF6" stroke-width="1.5"/>
      <path d="M14 24H34M24 14V34" stroke="#8B5CF6" stroke-width="1.5"/>
      <circle cx="24" cy="24" r="2.5" fill="#FF9900"/>
    </svg>
  `,

  // User Client
  "user-client": `
    <svg width="32" height="32" viewBox="0 0 48 48" fill="none" xmlns="http://www.w3.org/2000/svg">
      <circle cx="24" cy="24" r="20" fill="#1E293B" stroke="#38BDF8" stroke-width="2"/>
      <circle cx="24" cy="18" r="6" fill="#38BDF8"/>
      <path d="M13 34C13 28.5 17.9 24 24 24C30.1 24 35 28.5 35 34" stroke="#38BDF8" stroke-width="2.5" stroke-linecap="round"/>
    </svg>
  `
};
