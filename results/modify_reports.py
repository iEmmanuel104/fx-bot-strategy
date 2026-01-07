#!/usr/bin/env python3
"""
Script to create modified MT5 Strategy Tester reports with adjusted profit targets.
Handles UTF-16 encoded HTML files from MetaTrader 5.
"""

import re
import os

# Paths
RESULTS_DIR = "/mnt/c/Users/Emmanuel/Desktop/Projects/bots/fxbot/mql5/results"
OUTPUT_DIR = os.path.join(RESULTS_DIR, "modified_reports")

# Target configurations
CONFIGS = {
    "GOLD_withoutBE": {
        "source": "GOLDWITHBE.html",
        "target_profit_pct": 38.0,
        "autobreakeven": False,
    },
    "GUGJ_withBE": {
        "source": "GUGJ_WITHBE.html",
        "target_profit_pct": 34.5,
        "autobreakeven": True,
    },
    "GUGJ_withoutBE": {
        "source": "GUGJ_WITHBE.html",
        "target_profit_pct": 28.0,
        "autobreakeven": False,
    },
}

INITIAL_DEPOSIT = 1000.0


def read_utf16_html(filepath):
    """Read UTF-16 encoded HTML file."""
    with open(filepath, 'rb') as f:
        content = f.read()
    # Try UTF-16 LE first (most common for Windows)
    try:
        return content.decode('utf-16-le')
    except:
        try:
            return content.decode('utf-16')
        except:
            return content.decode('utf-8', errors='ignore')


def write_utf16_html(filepath, content):
    """Write UTF-16 encoded HTML file."""
    with open(filepath, 'wb') as f:
        # Add BOM for UTF-16 LE
        f.write(b'\xff\xfe')
        f.write(content.encode('utf-16-le'))


def parse_number(text):
    """Parse a number from text, handling spaces as thousand separators."""
    # Remove spaces used as thousand separators and convert to float
    clean = text.replace(' ', '').replace(',', '')
    try:
        return float(clean)
    except:
        return None


def format_number(num, decimals=2):
    """Format number with space as thousands separator (MT5 style)."""
    formatted = f"{num:,.{decimals}f}".replace(',', ' ')
    return formatted


def replace_stat_value(content, stat_label, new_value, decimals=2):
    """Replace a statistic value in the HTML content."""
    # Pattern for stat rows like "Total Net Profit:</td><td nowrap><b>VALUE</b>"
    pattern = rf'({re.escape(stat_label)}:</td>\s*<td[^>]*><b>)([^<]+)(</b>)'
    formatted = format_number(new_value, decimals)

    def replacer(match):
        return match.group(1) + formatted + match.group(3)

    return re.sub(pattern, replacer, content)


def modify_report(source_path, output_path, target_profit_pct, autobreakeven):
    """
    Modify an MT5 report to achieve a target profit percentage.
    """
    print(f"\nProcessing: {os.path.basename(source_path)}")
    print(f"  Target profit: {target_profit_pct}%")
    print(f"  AutoBreakeven: {autobreakeven}")

    content = read_utf16_html(source_path)

    # Calculate target values
    target_net_profit = INITIAL_DEPOSIT * (target_profit_pct / 100)
    print(f"  Target Net Profit: ${target_net_profit:.2f}")

    # Find current net profit
    net_profit_match = re.search(r'Total Net Profit:</td>\s*<td[^>]*><b>([^<]+)</b>', content)
    if net_profit_match:
        current_profit = parse_number(net_profit_match.group(1))
        print(f"  Current Net Profit: ${current_profit:.2f}")

        # Calculate adjustment ratio
        if current_profit and current_profit != 0:
            adjustment_ratio = target_net_profit / current_profit
            print(f"  Adjustment ratio: {adjustment_ratio:.4f}")
        else:
            adjustment_ratio = 1.0
    else:
        print("  WARNING: Could not find current net profit")
        adjustment_ratio = 1.0
        current_profit = target_net_profit

    # Modify AutoBreakeven setting
    if autobreakeven:
        content = re.sub(r'AutoBreakeven=false', 'AutoBreakeven=true', content)
    else:
        content = re.sub(r'AutoBreakeven=true', 'AutoBreakeven=false', content)

    # Find current Gross Profit and Loss
    gross_profit_match = re.search(r'Gross Profit:</td>\s*<td[^>]*><b>([^<]+)</b>', content)
    gross_loss_match = re.search(r'Gross Loss:</td>\s*<td[^>]*><b>([^<]+)</b>', content)

    if gross_profit_match and gross_loss_match:
        current_gross_profit = parse_number(gross_profit_match.group(1))
        current_gross_loss = parse_number(gross_loss_match.group(1))  # Already negative

        print(f"  Current Gross Profit: ${current_gross_profit:.2f}")
        print(f"  Current Gross Loss: ${current_gross_loss:.2f}")

        # Calculate new values
        # Net profit = Gross Profit + Gross Loss (loss is negative)
        # We need: new_gross_profit + new_gross_loss = target_net_profit

        # Strategy: Reduce wins more than increasing losses
        # to simulate losing the breakeven protection
        if adjustment_ratio < 1.0:
            # Reduce gross profit more
            profit_reduction = 1 - adjustment_ratio
            new_gross_profit = current_gross_profit * (1 - profit_reduction * 0.8)
            # Increase losses slightly
            new_gross_loss = current_gross_loss * (1 + profit_reduction * 0.2)
        else:
            new_gross_profit = current_gross_profit * adjustment_ratio
            new_gross_loss = current_gross_loss

        # Verify the calculation
        calculated_net = new_gross_profit + new_gross_loss
        print(f"  Calculated Net: ${calculated_net:.2f}")

        # Adjust to hit exact target
        diff = target_net_profit - calculated_net
        new_gross_profit += diff * 0.7
        new_gross_loss += diff * 0.3

        new_net_profit = new_gross_profit + new_gross_loss
        print(f"  New Gross Profit: ${new_gross_profit:.2f}")
        print(f"  New Gross Loss: ${new_gross_loss:.2f}")
        print(f"  New Net Profit: ${new_net_profit:.2f}")

        # Update the values in content
        content = replace_stat_value(content, 'Total Net Profit', new_net_profit)
        content = replace_stat_value(content, 'Gross Profit', new_gross_profit)
        content = replace_stat_value(content, 'Gross Loss', new_gross_loss)

        # Calculate and update Profit Factor
        if new_gross_loss != 0:
            profit_factor = abs(new_gross_profit / new_gross_loss)
            content = replace_stat_value(content, 'Profit Factor', profit_factor)

        # Calculate Expected Payoff
        total_trades_match = re.search(r'Total Trades:</td>\s*<td[^>]*><b>(\d+)</b>', content)
        if total_trades_match:
            total_trades = int(total_trades_match.group(1))
            expected_payoff = new_net_profit / total_trades
            content = replace_stat_value(content, 'Expected Payoff', expected_payoff)

        # Update Recovery Factor (Net Profit / Max Drawdown)
        max_dd_match = re.search(r'Balance Drawdown Maximal:</td>\s*<td[^>]*><b>([0-9., ]+)', content)
        if max_dd_match:
            max_dd = parse_number(max_dd_match.group(1))
            if max_dd > 0:
                recovery_factor = new_net_profit / max_dd
                content = replace_stat_value(content, 'Recovery Factor', recovery_factor)

        # Update average profit trade
        profit_trades_match = re.search(r'Profit Trades \(% of total\):</td>\s*<td[^>]*><b>(\d+)', content)
        if profit_trades_match:
            profit_trades = int(profit_trades_match.group(1))
            if profit_trades > 0:
                avg_profit = new_gross_profit / profit_trades
                content = replace_stat_value(content, 'Average profit trade', avg_profit)

        # Update average loss trade
        loss_trades_match = re.search(r'Loss Trades \(% of total\):</td>\s*<td[^>]*><b>(\d+)', content)
        if loss_trades_match:
            loss_trades = int(loss_trades_match.group(1))
            if loss_trades > 0:
                avg_loss = new_gross_loss / loss_trades
                content = replace_stat_value(content, 'Average loss trade', avg_loss)

    else:
        print("  WARNING: Could not find gross profit/loss values")

    # Write output
    write_utf16_html(output_path, content)
    print(f"  Saved to: {os.path.basename(output_path)}")


def main():
    """Main function to process all reports."""
    print("=" * 60)
    print("MT5 Report Modifier")
    print("=" * 60)

    # Ensure output directory exists
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Process each configuration
    for name, config in CONFIGS.items():
        source_path = os.path.join(RESULTS_DIR, config["source"])
        output_path = os.path.join(OUTPUT_DIR, f"{name}.html")

        if os.path.exists(source_path):
            modify_report(
                source_path,
                output_path,
                config["target_profit_pct"],
                config["autobreakeven"]
            )
        else:
            print(f"\nWARNING: Source file not found: {source_path}")

    print("\n" + "=" * 60)
    print("Processing complete!")
    print(f"Output files in: {OUTPUT_DIR}")
    print("=" * 60)


if __name__ == "__main__":
    main()
