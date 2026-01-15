import pandas as pd
import base64
import json
import glob
import os
import argparse
import time

def process_csvs(folder_path, column_idx):
    results = {}
    pattern = os.path.join(folder_path, '*.csv')

    for file_path in glob.glob(pattern):
        try:
            df = pd.read_csv(file_path, header=None, dtype=str)
            for _, row in df.iterrows():
                if len(row) > column_idx:
                    key, encoded_item = row.iloc[0], row.iloc[column_idx]
                    if pd.notna(key) and pd.notna(encoded_item):
                        try:
                            results[key] = base64.b64decode(encoded_item).decode('utf-8')
                        except Exception:
                            pass
        except Exception:
            pass
    return results

if __name__ == "__main__":
    start_time = time.monotonic()

    parser = argparse.ArgumentParser()
    parser.add_argument("folder_path", help="Folder containing the CSV files.")
    parser.add_argument("output_file", help="Output JSON file.")
    parser.add_argument(
        "--language",
        required=True,
        choices=['korean', 'english', 'portuguese', 'spanish']
    )
    args = parser.parse_args()

    language_map = {'korean': 1, 'english': 2, 'portuguese': 3, 'spanish': 4}
    selected_column = language_map[args.language]

    if not os.path.isdir(args.folder_path):
        print(f"Error: Folder not found: {args.folder_path}")
        exit(1)

    raw_data = process_csvs(args.folder_path, selected_column)
    
    if not raw_data:
        print("Warning: No data found.")
        exit(0)

    sorted_keys = sorted(raw_data.keys(), key=lambda k: (len(k), k))
    sorted_data = {key: raw_data[key] for key in sorted_keys}

    use_ascii_encoding = args.language in ('english', 'portuguese', 'spanish')
    
    output_string = json.dumps(
        sorted_data,
        indent=2,
        ensure_ascii=use_ascii_encoding,
        sort_keys=False
    )

    try:
        with open(args.output_file, 'wb') as f:
            f.write(output_string.encode('utf-8'))
        print(f"File generated: {args.output_file}")
    except IOError as e:
        print(f"Error saving file: {e}")
        exit(1)
    
    duration = time.monotonic() - start_time
    print(f"Execution time: {duration:.2f} seconds")