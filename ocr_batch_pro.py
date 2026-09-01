#!/usr/bin/env python3
"""
OCR PDF Converter - Batch Processing
Cross-platform CLI with native file dialogs and batch PDF to Word/TXT/Pages conversion
"""

import pdf2image
import pytesseract
import cv2
import numpy as np
from PIL import Image
import os
import subprocess
from pathlib import Path
from docx import Document
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
import sys
import traceback


class OCRConverter:
    """Handles PDF → OCR → Word/TXT/Pages conversion with batch support."""

    def __init__(self, output_format, preprocess, denoise_strength, threshold_value):
        self.output_format = output_format
        self.preprocess = preprocess
        self.denoise_strength = denoise_strength
        self.threshold_value = threshold_value

    def preprocess_image(self, image):
        """Apply denoise and threshold to image."""
        try:
            cv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
            gray = cv2.cvtColor(cv_image, cv2.COLOR_BGR2GRAY)

            if self.denoise_strength > 0:
                denoised = cv2.fastNlMeansDenoising(
                    gray,
                    h=self.denoise_strength,
                    templateWindowSize=7,
                    searchWindowSize=21
                )
            else:
                denoised = gray

            if self.threshold_value > 0:
                thresholded = cv2.adaptiveThreshold(
                    denoised,
                    255,
                    cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                    cv2.THRESH_BINARY,
                    blockSize=self.threshold_value,
                    C=2
                )
            else:
                thresholded = denoised

            return Image.fromarray(thresholded)
        except Exception as e:
            print(f"⚠️  Preprocessing error: {str(e)}")
            return image

    def extract_text(self, pdf_path):
        """Extract text from PDF."""
        try:
            print(f"  📄 Loading: {Path(pdf_path).name}")
            images = pdf2image.convert_from_path(pdf_path, dpi=300, fmt='ppm')
            total_pages = len(images)
            print(f"  ✓ {total_pages} pages")

            extracted_pages = []

            for page_num in range(total_pages):
                try:
                    image = images[page_num]
                    if self.preprocess:
                        image = self.preprocess_image(image)
                    text = pytesseract.image_to_string(image)
                    extracted_pages.append({
                        'page_num': page_num + 1,
                        'text': text.strip() if text else "[No text detected]"
                    })
                except Exception as e:
                    extracted_pages.append({
                        'page_num': page_num + 1,
                        'text': f"[OCR failed]"
                    })

            return extracted_pages
        except Exception as e:
            print(f"  ❌ Error: {str(e)}")
            return None

    def save_as_docx(self, pdf_path, output_dir, extracted_pages):
        """Save as Word document."""
        try:
            doc = Document()
            pdf_name = Path(pdf_path).stem

            title = doc.add_heading('OCR Conversion Report', level=0)
            title.alignment = WD_ALIGN_PARAGRAPH.CENTER

            meta = doc.add_paragraph(f"Source: {pdf_name}\nPages: {len(extracted_pages)}")
            meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
            doc.add_paragraph()

            for page_data in extracted_pages:
                doc.add_heading(f'Page {page_data["page_num"]}', level=2)
                doc.add_paragraph(page_data['text'])

            output_file = os.path.join(output_dir, f"{pdf_name}_OCR.docx")
            doc.save(output_file)
            return output_file
        except Exception as e:
            print(f"  ❌ Error saving DOCX: {str(e)}")
            return None

    def save_as_txt(self, pdf_path, output_dir, extracted_pages):
        """Save as plain text."""
        try:
            pdf_name = Path(pdf_path).stem
            output_file = os.path.join(output_dir, f"{pdf_name}_OCR.txt")

            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(f"OCR Conversion: {pdf_name}\n")
                f.write(f"Pages: {len(extracted_pages)}\n")
                f.write("=" * 80 + "\n\n")

                for page_data in extracted_pages:
                    f.write(f"--- Page {page_data['page_num']} ---\n")
                    f.write(page_data['text'])
                    f.write("\n\n")

            return output_file
        except Exception as e:
            print(f"  ❌ Error saving TXT: {str(e)}")
            return None


    def convert_pdf(self, pdf_path, output_dir):
        """Convert a single PDF."""
        extracted_pages = self.extract_text(pdf_path)
        if not extracted_pages:
            return None

        if self.output_format == 'Word (.docx)':
            return self.save_as_docx(pdf_path, output_dir, extracted_pages)
        elif self.output_format == 'Plain Text (.txt)':
            return self.save_as_txt(pdf_path, output_dir, extracted_pages)


def pick_pdfs():
    """Use native macOS file dialog to pick PDF(s)."""
    script = '''
    set pdf_files to (choose file of type {"com.adobe.pdf"} with prompt "Select PDF file(s):" with multiple selections allowed)
    set result to {}
    repeat with pdf_file in pdf_files
        set end of result to (POSIX path of pdf_file)
    end repeat
    return result
    '''
    result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip().split('\n')
    return []


def pick_output_folder():
    """Use native macOS file dialog to pick output folder."""
    script = '''
    set output_folder to (choose folder with prompt "Select output folder:")
    POSIX path of output_folder
    '''
    result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
    if result.returncode == 0:
        return result.stdout.strip()
    return str(Path.home() / 'Downloads')


def main():
    """Main application."""
    print("\n" + "="*70)
    print("  OCR PDF Converter (Batch Processing)")
    print("="*70 + "\n")

    # Pick PDFs
    print("📁 Select PDF file(s)...")
    pdf_files = pick_pdfs()
    if not pdf_files or pdf_files[0] == '':
        print("❌ No PDFs selected")
        return

    # Pick output folder
    print("📁 Select output folder...")
    output_dir = pick_output_folder()

    # Ask for format
    print("\n📋 Output format:")
    print("  1) Word (.docx)")
    print("  2) Plain Text (.txt)")
    choice = input("  Enter choice (1-2): ").strip()

    formats = {
        '1': 'Word (.docx)',
        '2': 'Plain Text (.txt)'
    }
    output_format = formats.get(choice, 'Word (.docx)')

    # Ask for preprocessing
    preprocess_choice = input("\n🔧 Enable preprocessing? (y/n, default y): ").strip().lower()
    preprocess = preprocess_choice != 'n'

    denoise = 10
    threshold = 11

    if preprocess:
        try:
            denoise_str = input("  Denoise strength (0-20, default 10): ").strip()
            denoise = int(denoise_str) if denoise_str else 10
        except:
            pass

        try:
            threshold_str = input("  Threshold block size (0-50, default 11): ").strip()
            threshold = int(threshold_str) if threshold_str else 11
        except:
            pass

    # Process files
    print("\n" + "="*70)
    converter = OCRConverter(output_format, preprocess, denoise, threshold)

    results = []
    for i, pdf_path in enumerate(pdf_files, 1):
        print(f"\n[{i}/{len(pdf_files)}] Processing...")
        output_file = converter.convert_pdf(pdf_path, output_dir)
        if output_file:
            print(f"  ✅ Saved: {Path(output_file).name}")
            results.append(output_file)
        else:
            print(f"  ❌ Failed")

    # Summary
    print("\n" + "="*70)
    if results:
        print(f"✅ Completed: {len(results)}/{len(pdf_files)} files")
        print(f"📁 Output folder: {output_dir}\n")

        # Ask to open results
        open_choice = input("Open output folder? (y/n): ").strip().lower()
        if open_choice == 'y':
            subprocess.run(['open', output_dir])
    else:
        print("❌ No files converted")

    print("="*70 + "\n")


if __name__ == '__main__':
    main()
